#include <gazebo/msgs/msgs.hh>
#include <list>
#include <map>
#include <mutex>
#include <string>

// A queue-only fixture for the unchanged native producer method bodies.
// No world, graphics context, ROS node or private native member access.
namespace gazebo { namespace rendering {
using PoseMsgs_M = std::map<uint32_t, msgs::Pose>;
struct QueueState {
  std::mutex* receiveMutex;
  std::recursive_mutex poseMsgMutex;
  PoseMsgs_M poseMsgs;
  std::list<boost::shared_ptr<const msgs::Visual>> modelVisualMsgs, linkVisualMsgs, visualMsgs, collisionVisualMsgs;
  std::list<boost::shared_ptr<const msgs::Joint>> jointMsgs;
  std::list<boost::shared_ptr<const msgs::Sensor>> sensorMsgs;
  std::list<boost::shared_ptr<const msgs::Link>> linkMsgs;
  std::list<boost::shared_ptr<const msgs::Light>> lightFactoryMsgs;
  std::list<boost::shared_ptr<const msgs::Model>> modelMsgs;
};
class Scene {
 public:
  std::mutex receiver;
  QueueState state;
  QueueState* dataPtr = &state;
  Scene() { state.receiveMutex = &receiver; }
  bool ProcessModelMsg(const msgs::Model&);
  bool ProcessSceneMsg(ConstScenePtr&);
  void OnVisualMsg(ConstVisualPtr&);
  void OnJointMsg(ConstJointPtr&);
  void OnSensorMsg(ConstSensorPtr&);
  void OnModelMsg(ConstModelPtr&);
  void OnLightFactoryMsg(ConstLightPtr&);
};
}}

// NATIVE_PRODUCER_METHODS
#include <chrono>
#include <future>
#include <iostream>
#include <functional>
#include <vector>
using namespace gazebo;
using namespace gazebo::rendering;

bool check(const char* label, const std::function<void(Scene&)>& producer) {
  Scene scene;
  std::unique_lock<std::mutex> consumer(scene.receiver);
  std::promise<void> entered;
  auto started = entered.get_future();
  auto job = std::async(std::launch::async, [&] { entered.set_value(); producer(scene); });
  started.wait();
  // Assert synchronization, never concurrently mutate a corruptible list.
  bool blocked = job.wait_for(std::chrono::milliseconds(60)) == std::future_status::timeout;
  consumer.unlock();
  bool completed = job.wait_for(std::chrono::seconds(1)) == std::future_status::ready;
  if (completed) job.get();
  auto& q=scene.state;
  const auto retained=q.visualMsgs.size()+q.jointMsgs.size()+q.sensorMsgs.size()+q.modelMsgs.size()+q.lightFactoryMsgs.size();
  const bool correct=blocked && completed && retained == 1;
  std::cout << (correct ? "PASS " : "FAIL ") << label
            << " blocksWithConsumer=" << blocked << " completesAfterRelease=" << completed
            << " retainedMessages=" << retained << '\n';
  return correct;
}

int main() {
  bool good = true;
  good &= check("model visual", [](Scene& s) {
    msgs::Model m; m.set_name("robot"); auto* l=m.add_link(); l->set_name("body");
    l->add_visual()->set_name("link"); l->add_visual()->set_name("geometry"); s.ProcessModelMsg(m);
  });
  good &= check("model joint", [](Scene& s) {
    msgs::Model m; m.set_name("robot"); m.add_joint()->set_name("joint"); s.ProcessModelMsg(m);
  });
  good &= check("model sensor", [](Scene& s) {
    msgs::Model m; m.set_name("robot"); auto* l=m.add_link(); l->set_name("body");
    l->add_sensor()->set_name("sensor"); s.ProcessModelMsg(m);
  });
  good &= check("nested model", [](Scene& s) {
    msgs::Model m; m.set_name("robot"); m.add_model()->set_name("nested"); s.ProcessModelMsg(m);
  });
  good &= check("model light", [](Scene& s) {
    msgs::Model m; m.set_name("robot"); auto* l=m.add_link(); l->set_name("body");
    l->add_light()->set_name("light"); s.ProcessModelMsg(m);
  });
  good &= check("scene light", [](Scene& s) {
    auto m=boost::shared_ptr<msgs::Scene>(new msgs::Scene); m->add_light()->set_name("light");
    ConstScenePtr c=m; s.ProcessSceneMsg(c);
  });
  good &= check("scene joint", [](Scene& s) {
    auto m=boost::shared_ptr<msgs::Scene>(new msgs::Scene); m->add_joint()->set_name("joint");
    ConstScenePtr c=m; s.ProcessSceneMsg(c);
  });
  good &= check("scene pose-to-model visual", [](Scene& s) {
    auto m=boost::shared_ptr<msgs::Scene>(new msgs::Scene); auto* r=m->add_model(); r->set_name("robot"); r->set_id(1);
    auto* l=r->add_link(); l->set_name("body"); l->add_visual()->set_name("link"); l->add_visual()->set_name("geometry");
    ConstScenePtr c=m; s.ProcessSceneMsg(c);
  });
  return good ? 0 : 1;
}
