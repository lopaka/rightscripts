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

# Check if security updates are enabled.  If not, exit.
if [[ $SECURITY_UPDATES != "enable" ]]; then
  echo "Security Updates not enabled"
  exit
fi

case $RS_DISTRO in
(centos|redhatenterpriseserver)
  sed --in-place 's%/archive/20[0-9]*%/archive/latest%' /etc/yum.repos.d/*.repo
  yum makecache
  yum --security update
  #  for glibc update on centos 6.6 and 7.0: yum update glibc
  ;;
(ubuntu|debian)
  sed --in-place 's%ubuntu_daily/.* $(lsb_release -cs)-security%ubuntu_daily/latest $(lsb_release -cs)-security%' /etc/apt/sources.list.d/rightscale.sources.list
  apt-get --yes update
  apt-get --yes dist-upgrade
  ;;
(*)
  echo "unsupported distribution '$RS_DISTRO'!"
  exit 1
  ;;
esac
