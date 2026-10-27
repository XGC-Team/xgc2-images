#!/usr/bin/env python3
"""Check the installed Noetic MAVROS vision plugin without starting ROS."""
import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


def check(prefix):
    package = prefix / 'share/mavros_extras/package.xml'
    plugins = prefix / 'share/mavros_extras/mavros_plugins.xml'
    library = prefix / 'lib/libmavros_extras.so'
    for path in (package, plugins, library):
        if not path.is_file() or not os.access(str(path), os.R_OK) or path.stat().st_size == 0:
            raise ValueError('missing or unreadable MAVROS extras file: {}'.format(path))
    manifest = ET.parse(str(package)).getroot()
    export = manifest.find('./export/mavros')
    if export is None or export.get('plugin') != '${prefix}/mavros_plugins.xml':
        raise ValueError('MAVROS extras plugin export is missing')
    root = ET.parse(str(plugins)).getroot()
    if root.tag != 'library' or root.get('path') != 'lib/libmavros_extras':
        raise ValueError('MAVROS extras plugin library declaration is missing')
    expected = ('vision_pose_estimate', 'mavros::extra_plugins::VisionPoseEstimatePlugin',
                'mavros::plugin::PluginBase')
    if not any((item.get('name'), item.get('type'), item.get('base_class_type')) == expected
               for item in root.findall('class')):
        raise ValueError('MAVROS vision_pose_estimate plugin class is missing')


if __name__ == '__main__':
    try:
        check(Path('/opt/ros/noetic'))
    except (OSError, ValueError, ET.ParseError) as exc:
        print('MAVROS vision plugin check: {}'.format(exc), file=sys.stderr)
        sys.exit(1)
    print('MAVROS vision_pose_estimate plugin declaration and library: OK')
