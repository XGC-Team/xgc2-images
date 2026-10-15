#!/usr/bin/env python3
"""Compile the exact Visual::Load shininess block against real Ignition8/Gazebo SDK."""
import argparse,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--visual',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);args=p.parse_args();source=args.visual.read_text();start=source.index('  if (this->dataPtr->sdf->HasElement("material"))',source.index('void Visual::Load()'));opening=source.index('{',start);depth=1;end=opening+1
while depth:
 if source[end]=='{':depth+=1
 elif source[end]=='}':depth-=1
 end+=1
body=source[start:end];assert body.count('node.Request(')==1;body=body.replace('ignition::transport::Node node;','TrackedNode node;')
pre=r'''
#include <gazebo/msgs/any.pb.h>
#include <ignition/msgs/stringmsg.pb.h>
#include <ignition/transport/Node.hh>
#include <ignition/transport/TopicUtils.hh>
#include <chrono>
#include <iostream>
#include <memory>
#include <vector>
#define gzerr std::cerr
namespace msgs = gazebo::msgs;
struct TrackedNode : ignition::transport::Node {
 static inline int preflights=0;
 bool ServiceInfo(const std::string& name,std::vector<ignition::transport::ServicePublisher>& out) const {
  ++preflights; return ignition::transport::Node::ServiceInfo(name,out);
 }
};
struct Config { bool material=true; bool HasElement(const std::string&) const {return material;} };
struct Data { std::shared_ptr<Config> sdf=std::make_shared<Config>(); double shininess=17.; };
struct VisualFixture { std::shared_ptr<Data> dataPtr=std::make_shared<Data>(); std::string name="fixture::visual"; const std::string& Name()const{return name;} void Load() {
'''
post=r'''
} };
int main(){
 ignition::transport::Node world; int callbacks=0;
 std::function<bool(const ignition::msgs::StringMsg&,gazebo::msgs::Any&)> serve=[&](const ignition::msgs::StringMsg& req,gazebo::msgs::Any& reply){++callbacks;reply.set_type(gazebo::msgs::Any::DOUBLE);reply.set_double_value(27.5);return req.data()!="fixture::failure";};
 if(!world.Advertise("/shininess",serve))return 2;
 int passed=0;auto begin=std::chrono::steady_clock::now();
 VisualFixture success;success.Load();bool success_ok=success.dataPtr->shininess==27.5&&callbacks==1&&TrackedNode::preflights==0;passed+=success_ok;std::cout<<"success_local_shininess="<<success_ok<<"\n";
 VisualFixture failed;failed.name="fixture::failure";failed.Load();bool failed_ok=failed.dataPtr->shininess==17.&&callbacks==2&&TrackedNode::preflights==0;passed+=failed_ok;std::cout<<"failed_response_preserves_material="<<failed_ok<<"\n";
 VisualFixture absent;absent.dataPtr->sdf->material=false;int before=callbacks;int preflight=TrackedNode::preflights;absent.Load();bool absent_ok=absent.dataPtr->shininess==17.&&callbacks==before&&TrackedNode::preflights==preflight;passed+=absent_ok;std::cout<<"no_material_no_request="<<absent_ok<<"\n";
 std::cout<<"passed="<<passed<<"/3 preflights="<<TrackedNode::preflights<<" callbacks="<<callbacks<<" elapsed_seconds="<<std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count()<<"\n";
 return passed==3?0:1;
}
'''
args.output.mkdir(parents=True,exist_ok=True);translation=args.output/'visual-shininess.test.cpp';translation.write_text(pre+body+post);binary=args.output/'visual-shininess.test';flags=subprocess.check_output(['pkg-config','--cflags','--libs','gazebo','ignition-transport8'],text=True).split();subprocess.run(['g++','-std=c++17','-O2',str(translation),'-o',str(binary),*flags],check=True);result=subprocess.run([str(binary)],capture_output=True,text=True);(args.output/'test.stdout').write_text(result.stdout);(args.output/'test.stderr').write_text(result.stderr);print(result.stdout,end='');raise SystemExit(result.returncode)
