#include <atomic>
#include <cstdint>
#include <cerrno>
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/epoll.h>
struct Counts { uint64_t sends, bytes, partial, again, epoll_out; };
namespace {
std::atomic<bool> active{false};
std::atomic<uint64_t> sends{0}, bytes{0}, partial{0}, again{0}, epoll_out{0};
}
extern "C" void tcp_count_begin() {
 active=false; sends=0; bytes=0; partial=0; again=0; epoll_out=0; active=true;
}
extern "C" Counts tcp_count_get() {
 return {sends.load(),bytes.load(),partial.load(),again.load(),epoll_out.load()};
}
extern "C" ssize_t send(int fd,const void* p,size_t n,int flags) {
 using F=ssize_t(*)(int,const void*,size_t,int);
 static F real=reinterpret_cast<F>(dlsym(RTLD_NEXT,"send"));
 const auto result=real(fd,p,n,flags); const int saved=errno;
 if(active.load()) { ++sends; if(result>0){bytes+=uint64_t(result);if(size_t(result)<n)++partial;}
  if(result<0&&(saved==EAGAIN||saved==EWOULDBLOCK))++again; }
 errno=saved; return result;
}
extern "C" int epoll_ctl(int epfd,int op,int fd,struct epoll_event* e) {
 using F=int(*)(int,int,int,struct epoll_event*);
 static F real=reinterpret_cast<F>(dlsym(RTLD_NEXT,"epoll_ctl"));
 const int result=real(epfd,op,fd,e); const int saved=errno;
 if(active.load()&&result==0&&e&&op!=EPOLL_CTL_DEL&&(e->events&EPOLLOUT))++epoll_out;
 errno=saved;return result;
}
