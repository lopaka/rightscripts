#!/usr/bin/env bash
#
# Copyright (C) 2015 RightScale, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -ex

if [[ -d '/etc/yum.repos.d' ]]; then
  # centos
  yum --assumeyes install gcc
elif [[ -d '/etc/apt' ]]; then
  # ubuntu
  apt-get --assume-yes install gcc build-essential
else
  echo "unsupported distribution!"
  exit 1
fi

wget --directory-prefix=/tmp https://raw.githubusercontent.com/lopaka/scratch/master/ghost.c 

gcc -o /tmp/ghost /tmp/ghost.c
