#include <ros/connection.h>
#include <ros/poll_manager.h>
#include <ros/poll_set.h>
#include <ros/publication.h>
#include <ros/serialized_message.h>
#include <ros/subscriber_link.h>
#include <ros/transport/transport_tcp.h>
#include <ros/transport/transport_udp.h>
#include <boost/make_shared.hpp>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <functional>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>
#include <arpa/inet.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>
struct Counts { uint64_t sends, bytes, partial, again, epoll_out; };
using Begin=void(*)();using Get=Counts(*)();
Begin begin_count;Get get_count;
void require(bool b,const char* m){if(!b)throw std::runtime_error(m);}
template<class F>void wait(F f,const char* message){
 auto end=std::chrono::steady_clock::now()+std::chrono::seconds(15);
 while(!f()){require(std::chrono::steady_clock::now()<end,message);std::this_thread::sleep_for(std::chrono::milliseconds(1));}
}
boost::shared_array<uint8_t> data(size_t n,uint8_t c){
 boost::shared_array<uint8_t> b(new uint8_t[n]);std::memset(b.get(),c,n);return b;
}
struct Fixture {
 ros::PollManager manager;
 ros::TransportTCPPtr transport;
 ros::ConnectionPtr connection;
 int peer=-1;
 std::thread reader;
 std::vector<uint8_t> received;
 std::atomic<size_t> count{0};
 std::atomic<unsigned> callbacks{0},drops{0};
 std::atomic<bool> inside{false},trailing{false},done{false};
 std::mutex mutex;std::function<void()> job;
 Fixture() {
  int listener=::socket(AF_INET,SOCK_STREAM,0);require(listener>=0,"listener");
  int small=4096;require(::setsockopt(listener,SOL_SOCKET,SO_RCVBUF,&small,sizeof(small))==0,"rcvbuf");
  sockaddr_in address{};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  require(::bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0,"bind");
  socklen_t length=sizeof(address);require(::getsockname(listener,reinterpret_cast<sockaddr*>(&address),&length)==0,"getsockname");
  require(::listen(listener,1)==0,"listen");
  transport=boost::make_shared<ros::TransportTCP>(&manager.getPollSet(),0);
  require(transport->connect("127.0.0.1",ntohs(address.sin_port)),"connect");
  peer=::accept(listener,nullptr,nullptr);::close(listener);require(peer>=0,"accept");
  // Resolve TransportTCP's existing async-connect check before case counters.
  // That check uses a temporary epoll watcher with POLLOUT of its own.
  uint8_t warm=0x7f;
  wait([&]{int n=transport->write(&warm,1);require(n>=0,"warm connect");return n==1;},"async connect");
  uint8_t echo=0;require(::recv(peer,&echo,1,MSG_WAITALL)==1&&echo==warm,"warm peer byte");
  connection=boost::make_shared<ros::Connection>();
  connection->initialize(transport,false,ros::HeaderReceivedFunc());
  connection->addDropListener([this](const ros::ConnectionPtr&,ros::Connection::DropReason){++drops;});
  manager.addPollThreadListener([this]{
   std::function<void()> call;{std::lock_guard<std::mutex> lock(mutex);call.swap(job);}
   if(call){trailing=false;call();done=true;}
  });
  manager.addPollThreadListener([this]{trailing=true;});
 }
 void start(){manager.start();}
 void submit(std::function<void()> f){
  done=false;{std::lock_guard<std::mutex> lock(mutex);require(!job,"pending fixture job");job=std::move(f);}
  manager.getPollSet().signal();
 }
 void read_peer(){
  require(!reader.joinable(),"reader twice");
  reader=std::thread([this]{uint8_t b[65536];for(;;){auto n=::recv(peer,b,sizeof(b),0);if(n<=0)break;received.insert(received.end(),b,b+n);count+=size_t(n);}});
 }
 void finish_read(size_t n){wait([&]{return count.load()>=n;},"receive timeout");::shutdown(peer,SHUT_RDWR);reader.join();require(received.size()==n,"byte count");}
 void verify(size_t first,uint8_t a,size_t second=0,uint8_t b=0){
  require(received.size()==first+second,"size mismatch");
  for(size_t i=0;i<first;++i)require(received[i]==a,"first bytes differ");
  for(size_t i=first;i<received.size();++i)require(received[i]==b,"second bytes differ");
 }
 ~Fixture(){
  if(connection)connection->drop(ros::Connection::Destructing);
  manager.shutdown();
  if(peer>=0){::shutdown(peer,SHUT_RDWR);::close(peer);}
  if(reader.joinable())reader.join();
 }
};
struct Link final:ros::SubscriberLink {
 ros::ConnectionPtr connection;Fixture& fixture;
 Link(ros::ConnectionPtr c,const ros::PublicationPtr& p,Fixture& f):connection(c),fixture(f){parent_=p;}
 void enqueueMessage(const ros::SerializedMessage& m,bool,bool)override{
  auto weak=parent_;auto* f=&fixture;
  connection->write(m.buf,uint32_t(m.num_bytes),[weak,f](const ros::ConnectionPtr&){
   require(!f->inside.load(),"completion within publication call");
   require(f->trailing.load(),"completion before entire poll signal exits");
   auto p=weak.lock();require(p&&p->getNumSubscribers()==1,"real publication lock reacquisition");++f->callbacks;
  },false);
 }
 void drop()override{connection->drop(ros::Connection::Destructing);}
 std::string getTransportType()override{return "real-tcp-test-adapter";}
 std::string getTransportInfo()override{return connection->getRemoteString();}
};
struct LifetimeControl {
 std::mutex mutex;std::condition_variable cv;
 std::atomic<bool> arm_copy{false},destroyed{false},violation{false};
 std::atomic<unsigned> callbacks{0};
 bool extracting=false,released=false,drop_started=false,drop_done=false;
};
struct OwnedLink;
struct RawCompletion {
 OwnedLink* owner;std::shared_ptr<LifetimeControl> control;
 RawCompletion(OwnedLink* p,std::shared_ptr<LifetimeControl> c):owner(p),control(std::move(c)){}
 RawCompletion(const RawCompletion& other):owner(other.owner),control(other.control){
  // Real boost::function copy inside Connection::writeTransport, after the
  // full-send test and before clearing/invoking its raw-this completion.
  if(control->arm_copy.exchange(false)){
   std::unique_lock<std::mutex> lock(control->mutex);
   control->extracting=true;control->cv.notify_all();
   control->cv.wait(lock,[&]{return control->released;});
  }
 }
 void operator()(const ros::ConnectionPtr&)const;
};
struct OwnedLink final:ros::SubscriberLink {
 ros::ConnectionPtr connection;std::shared_ptr<LifetimeControl> control;
 boost::signals2::connection listener;int marker=0x1234;
 OwnedLink(ros::ConnectionPtr c,const ros::PublicationPtr& p,std::shared_ptr<LifetimeControl> state)
  :connection(std::move(c)),control(std::move(state)){
  parent_=p;
  listener=connection->addDropListener([this](const ros::ConnectionPtr&,ros::Connection::DropReason){
   if(auto p=parent_.lock())p->removeSubscriberLink(shared_from_this());
  });
 }
 ~OwnedLink(){control->destroyed=true;control->cv.notify_all();drop();connection->removeDropListener(listener);}
 void enqueueMessage(const ros::SerializedMessage& m,bool,bool)override{
  connection->write(m.buf,uint32_t(m.num_bytes),RawCompletion(this,control),false);
  control->arm_copy=true;
 }
 void drop()override{connection->drop(ros::Connection::Destructing);}
 std::string getTransportType()override{return "real-tcp-raw-completion-lifetime";}
 std::string getTransportInfo()override{return connection->getRemoteString();}
};
void RawCompletion::operator()(const ros::ConnectionPtr&)const{
 // Report the positive loss-of-lifetime without dereferencing freed memory.
 if(control->destroyed.load())control->violation=true;
 else if(owner->marker!=0x1234)control->violation=true;
 ++control->callbacks;
}
void print(const std::string& c,const Counts& n){std::cout<<"{\"case\":\""<<c<<"\",\"sends\":"<<n.sends<<",\"bytes\":"<<n.bytes<<",\"partial\":"<<n.partial<<",\"eagain\":"<<n.again<<",\"epoll_out\":"<<n.epoll_out<<"}"<<std::endl;}
int main(int argc,char** argv){try{
 require(argc>=3,"case and library expectation required");::signal(SIGPIPE,SIG_IGN);
 begin_count=reinterpret_cast<Begin>(dlsym(RTLD_DEFAULT,"tcp_count_begin"));get_count=reinterpret_cast<Get>(dlsym(RTLD_DEFAULT,"tcp_count_get"));require(begin_count&&get_count,"counter absent");
 const std::string name=argv[1];const bool candidate=std::string(argv[2])=="candidate";
 if(argc>=4){std::ifstream in("/proc/self/maps");std::ofstream out(argv[3]);out<<in.rdbuf();}
 if(name=="full"){
  Fixture f;auto pub=boost::make_shared<ros::Publication>("/proof","bytes","md5","",1,false,false);
  pub->addSubscriberLink(boost::make_shared<Link>(f.connection,pub,f));auto buffer=data(4096,0x41);
  f.read_peer();f.start();f.submit([&]{begin_count();f.inside=true;require(pub->enqueueMessage(ros::SerializedMessage(buffer,4096)),"enqueue");f.inside=false;});
  wait([&]{return f.callbacks==1;},"full callback");auto n=get_count();f.finish_read(4096);f.verify(4096,0x41);print(name,n);
  require(n.sends>=1,"full actual send");require(n.epoll_out==(candidate?0u:1u),"full POLLOUT count");
 }else if(name=="partial"){
  Fixture f;constexpr size_t n=16*1024*1024;auto buffer=data(n,0x42);f.start();f.submit([&]{begin_count();f.connection->write(buffer,n,[&](const ros::ConnectionPtr&){++f.callbacks;},false);});
  wait([&]{return get_count().partial>0;},"no real partial observed");require(f.callbacks==0,"partial completed without peer drain");auto before=get_count();
  f.read_peer();wait([&]{return f.callbacks==1;},"partial completion");f.finish_read(n);f.verify(n,0x42);print("partial-before-peer-drain",before);print(name,get_count());
 }else if(name=="eagain"){
  Fixture f;auto filler=data(65536,0x50);size_t prefix=0;begin_count();
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
  while(get_count().again==0){require(prefix<32*1024*1024,"fill byte cap");require(std::chrono::steady_clock::now()<deadline,"fill time cap");int n=f.transport->write(filler.get(),65536);require(n>=0,"fill error");prefix+=size_t(n);}
  print("raw-prefill",get_count());auto payload=data(1024*1024,0x51);f.start();f.submit([&]{begin_count();f.connection->write(payload,1024*1024,[&](const ros::ConnectionPtr&){++f.callbacks;},false);});
  wait([&]{return f.done.load();},"eagain queued");
  if(candidate)wait([&]{return get_count().again>0;},"candidate drain EAGAIN not observed");
  require(f.callbacks==0,"eagain completed before peer drain");auto before=get_count();
  f.read_peer();wait([&]{return f.callbacks==1;},"eagain fallback completion");f.finish_read(prefix+1024*1024);f.verify(prefix,0x50,1024*1024,0x51);print("connection-before-peer-drain",before);print(name,get_count());
 }else if(name=="close"){
  Fixture f;auto buffer=data(4096,0x43);f.start();f.submit([&]{begin_count();f.connection->write(buffer,4096,[&](const ros::ConnectionPtr&){++f.callbacks;},false);f.connection->drop(ros::Connection::Destructing);});
  wait([&]{return f.done.load();},"close job");f.manager.shutdown();require(f.callbacks==0&&f.drops==1,"queued close callbacks");require(get_count().sends==0,"closed staged send");print(name,get_count());
  boost::weak_ptr<ros::Connection> weak=f.connection;f.connection.reset();require(weak.expired(),"batch retained dropped connection");
 }else if(name=="chain"){
  Fixture f;auto a=data(4096,0x61),b=data(4096,0x62);f.read_peer();f.start();f.submit([&]{begin_count();f.connection->write(a,4096,[&](const ros::ConnectionPtr& c){++f.callbacks;c->write(b,4096,[&](const ros::ConnectionPtr&){++f.callbacks;},false);},false);});
  wait([&]{return f.callbacks==2;},"chained callbacks");f.finish_read(8192);f.verify(4096,0x61,4096,0x62);print(name,get_count());
 }else if(name=="external"||name=="immediate"){
  Fixture f;auto buffer=data(4096,0x44);std::atomic<bool> sync{false};f.read_peer();f.start();
  if(name=="external"){begin_count();f.connection->write(buffer,4096,[&](const ros::ConnectionPtr&){++f.callbacks;},false);}
  else{f.submit([&]{begin_count();f.inside=true;f.connection->write(buffer,4096,[&](const ros::ConnectionPtr&){sync=f.inside.load();++f.callbacks;},true);f.inside=false;});}
  wait([&]{return f.callbacks==1;},"control callback");f.finish_read(4096);f.verify(4096,0x44);auto n=get_count();print(name,n);require(n.epoll_out==1,"legacy POLLOUT path changed");if(name=="immediate")require(sync,"immediate no longer immediate");
 }else if(name=="lifetime"){
  Fixture f;auto state=std::make_shared<LifetimeControl>();
  auto pub=boost::make_shared<ros::Publication>("/lifetime","bytes","md5","",1,false,false);
  pub->addSubscriberLink(boost::make_shared<OwnedLink>(f.connection,pub,state));
  auto bytes=data(4096,0x65);f.read_peer();f.start();
  f.submit([&]{begin_count();require(pub->enqueueMessage(ros::SerializedMessage(bytes,4096)),"lifetime enqueue");});
  {std::unique_lock<std::mutex> lock(state->mutex);require(state->cv.wait_for(lock,std::chrono::seconds(5),[&]{return state->extracting;}),"callback extraction not observed");}
  std::thread dropper([&]{
   {std::lock_guard<std::mutex> lock(state->mutex);state->drop_started=true;state->cv.notify_all();}
   f.connection->drop(ros::Connection::Destructing);
   {std::lock_guard<std::mutex> lock(state->mutex);state->drop_done=true;state->cv.notify_all();}
  });
  bool drop_before_callback;
  {std::unique_lock<std::mutex> lock(state->mutex);
   state->cv.wait(lock,[&]{return state->drop_started;});
   drop_before_callback=state->cv.wait_for(lock,std::chrono::milliseconds(300),[&]{return state->drop_done;});
   state->released=true;state->cv.notify_all();
  }
  dropper.join();wait([&]{return state->callbacks==1;},"lifetime callback");
  f.finish_read(4096);f.verify(4096,0x65);print(name,get_count());
  std::cout<<"{\"drop_completed_before_callback_release\":"<<(drop_before_callback?"true":"false")<<",\"owner_destroyed_before_callback\":"<<(state->violation?"true":"false")<<"}"<<std::endl;
  require(!drop_before_callback&&!state->violation,"concurrent drop destroyed raw completion owner");
 }else if(name=="foreign-pollset"){
  Fixture f;ros::PollManager other;std::atomic<bool> submitted{false};auto buffer=data(4096,0x66);
  f.read_peer();f.start();
  other.addPollThreadListener([&]{if(!submitted.exchange(true)){begin_count();f.connection->write(buffer,4096,[&](const ros::ConnectionPtr&){++f.callbacks;},false);}});
  other.start();wait([&]{return f.callbacks==1;},"foreign pollset callback");other.shutdown();
  f.finish_read(4096);f.verify(4096,0x66);auto n=get_count();print(name,n);require(n.epoll_out==1,"foreign PollSet staged");
 }else if(name=="udp"){
  ros::PollManager manager;int peer=::socket(AF_INET,SOCK_DGRAM,0);require(peer>=0,"udp socket");
  sockaddr_in address{};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  require(::bind(peer,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0,"udp bind");
  socklen_t length=sizeof(address);require(::getsockname(peer,reinterpret_cast<sockaddr*>(&address),&length)==0,"udp port");
  timeval timeout{5,0};require(::setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout))==0,"udp timeout");
  auto transport=boost::make_shared<ros::TransportUDP>(&manager.getPollSet(),0,1500);
  require(transport->connect("127.0.0.1",ntohs(address.sin_port),17),"udp connect");
  auto connection=boost::make_shared<ros::Connection>();connection->initialize(transport,false,ros::HeaderReceivedFunc());
  auto buffer=data(512,0x37);std::atomic<bool> submitted{false};std::atomic<unsigned> callbacks{0};
  manager.addPollThreadListener([&]{if(!submitted.exchange(true)){begin_count();connection->write(buffer,512,[&](const ros::ConnectionPtr&){++callbacks;},false);}});
  manager.start();wait([&]{return callbacks==1;},"udp callback");manager.shutdown();
  uint8_t bytes[1500];auto n=::recv(peer,bytes,sizeof(bytes),0);require(n==ssize_t(512+sizeof(ros::TransportUDPHeader)),"udp bytes");
  ros::TransportUDPHeader header{};std::memcpy(&header,bytes,sizeof(header));require(header.connection_id_==17&&header.op_==ROS_UDP_DATA0&&header.block_==1,"udp header");
  for(size_t i=sizeof(header);i<size_t(n);++i)require(bytes[i]==0x37,"udp payload");
  auto counts=get_count();print(name,counts);require(counts.epoll_out==1,"non TCP staged");
  connection->drop(ros::Connection::Destructing);::close(peer);
 }else if(name=="io-callback"){
  Fixture f;auto a=data(4096,0x71),b=data(4096,0x72);f.read_peer();f.start();begin_count();f.connection->write(a,4096,[&](const ros::ConnectionPtr& c){++f.callbacks;c->write(b,4096,[&](const ros::ConnectionPtr&){++f.callbacks;},false);},false);
  wait([&]{return f.callbacks==2;},"IO callback chain");f.finish_read(8192);f.verify(4096,0x71,4096,0x72);print(name,get_count());
 }else throw std::runtime_error("unknown case");
 return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<std::endl;return 1;}}
