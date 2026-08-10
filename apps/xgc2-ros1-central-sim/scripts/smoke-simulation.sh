#!/usr/bin/env bash
set -euo pipefail

export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"
source /opt/ros/noetic/setup.bash

roslaunch --files gazebo_sim_scout simple.launch rviz:=false >/dev/null
roslaunch --files gazebo_sim_fs150_sitl fs150.launch gui:=false >/dev/null
roslaunch --files gazebo_sim_mecanum simple.launch gui:=false >/dev/null
roslaunch --files gazebo_sim_vrpn_bridge vrpn_server.launch >/dev/null

echo "XGC2 central simulation launch files resolved successfully without starting or moving a robot."
