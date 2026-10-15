#!/usr/bin/env python3
"""Compile exact pinned Scene dispatch/response method bodies against narrow transport doubles.
No Gazebo World, GL, ROS, station run, or wall-time performance claim.
"""
import argparse, hashlib, json, subprocess
from pathlib import Path
p=Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--baseline',type=Path,required=True);parser.add_argument('--fixed',type=Path,required=True);parser.add_argument('--artifacts',type=Path,required=True);args=parser.parse_args();args.artifacts.mkdir(parents=True,exist_ok=True)
def method(s,signature):
 start=s.index(signature);end=s.index('\n/////////////////////////////////////////////////',start);return s[start:end]
def dispatch(s):
 start=s.index('void Scene::Init()');start=s.index('  this->dataPtr->originVisual->Load();',start)+len('  this->dataPtr->originVisual->Load();');end=s.index('\n  if (!this->dataPtr->isServer)',start);return 'void Scene::Dispatch() {\n'+s[start:end]+'}\n'
original=args.baseline.read_text();fixed=args.fixed.read_text()
for signature in ['void Scene::OnResponse(', 'void Scene::OnSceneInfo(']:
 assert method(original,signature)==method(fixed,signature),signature+' must be byte-identical'
results=[]
for label,source in [('RED',original),('GREEN',fixed)]:
 methods=dispatch(source)+'\n'+method(source,'void Scene::OnResponse(')+'\n'+method(source,'void Scene::OnSceneInfo(')
 translation=args.artifacts/(label+'.cpp');translation.write_text((p/'request-dispatch.test.cpp').read_text().replace('// PRODUCTION_METHODS',methods));executable=args.artifacts/label
 cmd=['g++','-std=c++17','-Wall','-Wextra','-Werror','-pthread',str(translation),'-o',str(executable)]
 built=subprocess.run(cmd,text=True,capture_output=True);(args.artifacts/(label+'-build.log')).write_text(built.stdout+built.stderr);built.check_returncode()
 result=subprocess.run([str(executable)],text=True,capture_output=True,timeout=10);(args.artifacts/(label+'.log')).write_text(result.stdout+result.stderr)
 results.append({'variant':label,'exit':result.returncode,'output':result.stdout,'sceneSHA256':hashlib.sha256(source.encode()).hexdigest()});print(label,result.stdout,end='')
 assert result.returncode==(1 if label=='RED' else 0)
(args.artifacts/'receipt.json').write_text(json.dumps({'scope':'Exact production dispatch snippet and unmodified response methods; transport doubles, not full Gazebo runtime or timing proof','results':results},indent=2))
