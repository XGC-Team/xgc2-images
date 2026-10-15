#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
namespace boost { using std::make_shared; }
namespace msgs {
struct Request { int value=71; std::string kind; int id() const { return value; } };
Request *CreateRequest(const std::string &kind) { auto *r=new Request; r->kind=kind; return r; }
struct Scene { std::string payload; bool ParseFromString(const std::string &s) { payload=s; return true; } };
struct Response { int value; std::string payload; int id() const {return value;} const std::string &serialized_data() const {return payload;} };
}
using ConstResponsePtr=std::shared_ptr<const msgs::Response>;
static int discoveryCalls=0, ignitionRequests=0;
namespace ignition { namespace transport {
struct ServicePublisher {};
struct Node {
 bool ServiceInfo(const std::string &, std::vector<ServicePublisher>&) {++discoveryCalls;return false;}
 template<class T> bool Request(const std::string &, void (T::*)(const msgs::Scene &,bool),T*) {++ignitionRequests;return false;}
};
}}
struct Publisher {
 int connections=0, sends=0;
 std::vector<msgs::Request> pending;
 void WaitForConnection() {++connections;}
 void Publish(const msgs::Request &r) {++sends;pending.push_back(r);}
};
struct Data {
 std::shared_ptr<Publisher> requestPub=std::make_shared<Publisher>();
 std::unique_ptr<msgs::Request> requestMsg;
 std::mutex mutex;
 std::mutex *receiveMutex=&mutex;
 std::vector<std::shared_ptr<const msgs::Scene>> sceneMsgs;
};
#define gzwarn std::cerr
#define gzerr std::cerr
struct Scene {
 Data storage;
 Data *dataPtr=&storage;
 void Dispatch();
 void OnSceneInfo(const msgs::Scene &,bool);
 void OnResponse(ConstResponsePtr &);
};
// PRODUCTION_METHODS
static void expect(bool b,const char *why) {if(!b) throw std::runtime_error(why);}
static ConstResponsePtr response(int id,const std::string &payload) {return std::make_shared<const msgs::Response>(msgs::Response{id,payload});}
int main() {
 int failures=0;
 for(int test=0;test<3;++test) {
  try {
   discoveryCalls=ignitionRequests=0; Scene scene; scene.Dispatch();
   if(test==0) {
    expect(discoveryCalls==0 && ignitionRequests==0,"dispatch entered Ignition discovery/service path");
    expect(scene.storage.requestPub->connections==1 && scene.storage.requestPub->sends==1,"expected one existing connection check and one queued publish");
    expect(scene.storage.requestMsg && scene.storage.requestPub->pending.size()==1,"request receipt must survive dispatch");
    expect(scene.storage.requestPub->pending[0].kind=="scene_info","scene_info request contract changed");
    expect(scene.storage.sceneMsgs.empty(),"dispatch must return before world response/render population");
   } else if(test==1) {
    auto foreign=response(999,"foreign");scene.OnResponse(foreign);
    expect(scene.storage.requestMsg && scene.storage.sceneMsgs.empty(),"foreign response consumed current request");
   } else {
    auto reply=response(scene.storage.requestMsg->id(),"neighbor+static+model scene payload");scene.OnResponse(reply);
    expect(!scene.storage.requestMsg && scene.storage.sceneMsgs.size()==1,"matching response did not consume request into scene queue");
    expect(scene.storage.sceneMsgs[0]->payload==reply->payload,"scene payload changed");
    scene.OnResponse(reply);expect(scene.storage.sceneMsgs.size()==1,"duplicate response populated scene twice");
   }
   std::cout<<"PASS case "<<test+1<<'\n';
  }catch(const std::exception &e) {++failures;std::cout<<"FAIL case "<<test+1<<": "<<e.what()<<'\n';}
 }
 std::cout<<3-failures<<"/3 PASS\n";return failures?1:0;
}
