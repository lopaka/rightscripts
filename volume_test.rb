#!/usr/bin/ruby

# add packages:
# centos - ruby19 rubygems19 ruby19-devel gcc
# ubuntu - ruby1.9.1 rubygems1.9.1 ruby1.9.1-dev rubygems1.9.1 gcc

require 'rubygems'

begin
  gem "right_api_client"
rescue LoadError
  system('gem install right_api_client --no-ri --no-rdoc')
  Gem.clear_paths
end

require 'right_api_client'
require 'syslog'

# log to stdout and syslog
def log(message)
  puts message
  Syslog.open('volume_testing', Syslog::LOG_PID | Syslog::LOG_CONS) { |s| s.warning message }
end

def initialize_api_client
  require "/var/spool/cloud/user-data.rb"
  account_id, instance_token = ENV["RS_API_TOKEN"].split(":")
  api_url = "https://#{ENV["RS_SERVER"]}"
  options = {
    :account_id => account_id,
    :instance_token => instance_token,
    :api_url => api_url,
    :timeout => nil,
  }

  client = RightApi::Client.new(options)
  client
end

def device_list(cloud_type)
  case cloud_type
  when "gce"
    (1..15).map { |e| "persistent-disk-#{e}" }
  when "cloudstack"
    (1..15).map { |e| "device_id:#{e}" }
  when "rackspace-ng"
    ('d'..'z').map{ |e| "/dev/xvd#{e}" }
  when "azure"
    (0..15).map { |e| sprintf('%02d', e) }
  when "openstack"
    ('c'..'z').map { |e| "/dev/vd#{e}" }
  when "ec2"
    ('j'..'m').map { |e| "/dev/sd#{e}" }
    ('d'..'h').map { |e| "xvd#{e}" }
  when "vsphere"
    # 'lsiLogic(0:0)', 'lsiLogic(0:1)', ... skipping *:7 which is reserved for the controller
    (0..3).to_a.product((0..15).to_a).map { |controller_id, node_id| node_id == 7 ? next : "lsiLogic(#{controller_id}:#{node_id})" }
  end
end

def get_current_devices
  partitions = IO.readlines('/proc/partitions').drop(2).map do |line|
    line.chomp.split.last
  end.reject do |partition|
    partition =~ /^dm-\d/
  end
  devices = partitions.select do |partition|
    partition =~ /[a-z]$/
  end.sort.map {|device| "/dev/#{device}"}
  if devices.empty?
    devices = partitions.select do |partition|
      partition =~ /[0-9]$/
    end.sort.map {|device| "/dev/#{device}"}
  end
  devices
end

def scan_for_attachments
  # Check for /sys/class/scsi_host/host*/scan files.
  scan_files = ::Dir.glob('/sys/class/scsi_host/host*/scan')
  scan_files.each do |scan_file|
    ::File.open(scan_file, 'w') { |file| file.puts '- - -' }
    sleep 1
  end
end

def scan_for_detachments
  # Get current list of block devices.
  current_devices = get_current_devices

  # Exclude '/dev/sda', which is often used for the / (root) partition, as we do not
  # want to remove the root partition device.
  current_devices.delete('/dev/sda')

  # Iterate through block devices if it should be removed.
  current_devices.each do |device|
    # If able to read directly from block device, assume it is still in use.
    device_available = begin
      ::File.binread(device, 8) ? true : false
    rescue Errno::EIO
      false
    end

    if device_available
      log " -- Device #{device} appears to still be in use - no changes made."
    else
      device_name = ::File.basename(device)
      scan_file = "/sys/block/#{device_name}/device/delete"
      if ::File.exist?(scan_file)
        log " -- Manual removal of #{device}."
        ::File.open(scan_file, 'w') { |file| file.puts '1' }
        sleep 1
      else
        log " -- Scan file #{scan_file} does not exists to remove #{device} - no changes made."
      end
    end
  end

end

# prevent restclient from logging to screen
RestClient.log = nil

@client = initialize_api_client
instance = @client.get_instance

# determine cloud type
cloud_type = IO.read('/etc/rightscale.d/cloud').strip

# set variables
size = cloud_type == "rackspace-ng" ? 100 : 10
volume_name = "QTEST VOLUME"
snapshot_name = "QTEST SNAPSHOT"
mount_point = '/mnt/storage'
testfile = mount_point + '/testfile'
md5_snap = nil
md5_orig = nil

multi_volume_count = 2

# Set required parameters
params = {
  :volume => {
    :name => volume_name,
    :description => "Testing volume/snapshot support",
    :size => size,
  }
}

datacenter_href = instance.links.detect { |link| link["rel"] == "datacenter" }
params[:volume][:datacenter_href] = datacenter_href["href"] if datacenter_href

log params[:volume][:datacenter_href]

# Some clouds require a volume_type parameter
params[:volume][:volume_type_href] =
  case cloud_type
  when 'rackspace-ng', 'vsphere'
    volume_types = @client.volume_types.index
    volume_type = volume_types.first

    volume_type.href
  when "cloudstack"
    volume_types = @client.volume_types.index
    custom_volume_types = volume_types.select { |type| type.size.to_i == 0 }

    if custom_volume_types.empty?
      volume_types.reject! { |type| type.size.to_i < size }
      minimum_size = volume_types.map { |type| type.size.to_i }.min
      volume_types.reject! { |type| type.size.to_i != minimum_size }
    else
      volume_types = custom_volume_types
    end

    if volume_types.empty?
      raise "Could not find a volume type that is large enough for #{size}"
    elsif volume_types.size == 1
      volume_type = volume_types.first
    elsif volume_types.first.resource_uid =~ /^[0-9]+$/
      log "Found multiple valid volume types"
      log "Using the volume type with the greatest numeric resource_uid"
      volume_type = volume_types.max_by { |type| type.resource_uid.to_i }
    else
      log "Found multiple valid volume types"
      log "Using the first returned valid volume type"
      volume_type = volume_types.first
    end

    if volume_type.size.to_i == 0
      log "Found volume type that supports custom sizes:" +
        " #{volume_type.name} (#{volume_type.resource_uid})"
    else
      log "Did not find volume type that supports custom sizes"
      log "Using closest volume type: #{volume_type.name} (#{volume_type.resource_uid}) which is #{volume_type.size} GB"
    end
    volume_type.href
  else
    nil
  end

log "SINGLE VOLUME - initial scanning for attached and detached devices"
scan_for_attachments
scan_for_detachments

initial_devices = get_current_devices

log "SINGLE VOLUME - Requests volume creation with params = #{params.inspect}"
# Create volume and wait until the volume becomes "available" or "provisioned"
created_volume = nil
Timeout::timeout(900) do
  created_volume = @client.volumes.create(params)
  # Wait until the volume is successfully created. A volume is said to be created
  # if volume status is "available" or "provisioned".
  name = created_volume.show.name
  while (status = created_volume.show.status) !~ /^available|provisioned$/
    log "SINGLE VOLUME - Waiting for volume '#{name}' to create...current status is '#{status}' - #{Time.now.utc}"
    raise "Creation of volume has failed." if status == "failed"
    sleep 2
  end
end

attachment_params = {
  :volume_attachment => {
    :volume_href => created_volume.show.href,
    :instance_href => instance.show.href,
    :device => device_list(cloud_type).first,
  }
}

log "SINGLE VOLUME - Requests volume attachment with params = #{attachment_params.inspect}"
# Attach volume and wait until the volume becomes "in-use"
Timeout::timeout(900) do
  attached_volume = @client.volume_attachments.create(attachment_params)
  name = created_volume.show.name
  while (state = attached_volume.show.state) != 'attached' && (status = created_volume.show.status) != 'in-use'
    log "SINGLE VOLUME - Waiting for volume #{name} to attach... Current state / status is #{state} / #{status} - #{Time.now.utc}"
    sleep 2
  end
  raise "Volume is attached to wrong device" if attached_volume.show.device.inspect.split('"')[1] != device_list(cloud_type).first
  raise "Volume attachment is failed" if @client.volume_attachments.index(:filter => ["volume_href==#{created_volume.show.href}"]).nil?
  scan_for_attachments
  log "SINGLE VOLUME - attached volume: #{attached_volume.inspect}"
end

log "SINGLE VOLUME - Formats the device and mounts it to a mount point"
actual_device = nil
Timeout::timeout(900) do
  scan_for_attachments
  log "SINGLE VOLUME - current devices: #{get_current_devices}"
  while get_current_devices.size == initial_devices.size
    log "SINGLE VOLUME - Waiting for discovering newly created device - #{Time.now.utc}"
    sleep 2
    scan_for_attachments
  end

  actual_device = (get_current_devices - initial_devices)[0].to_s

  log "SINGLE VOLUME - Formatting #{actual_device}..."
  scan_for_attachments
  raise Exception unless system("mkfs.ext3 -F #{actual_device}")

  log "SINGLE VOLUME - Mounting #{actual_device} at #{mount_point}..."
  raise Exception unless system("mkdir -p #{mount_point}")
  raise Exception unless system("mount #{actual_device} #{mount_point}")
end

log "SINGLE VOLUME - Generates testfile and calculates fingerprint of this file"
Timeout::timeout(900) do
  log "SINGLE VOLUME - Generating new testfile..."
  raise "#{testfile} not created" unless system("dd if=/dev/urandom of=#{testfile} bs=16M count=8")
  log "SINGLE VOLUME - Calculating fingerprint of testfile..."
  r = `md5sum #{testfile}`
  md5_orig = r.split(" ").first
  log "SINGLE VOLUME - md5_origin = #{md5_orig}"
end

snapshot_params = {
  :volume_snapshot => {
    :name => snapshot_name,
    :description => created_volume.show.description,
    :parent_volume_href => created_volume.show.href
  }
}

Timeout::timeout(900) do
  log "SINGLE VOLUME - Taking snapshot #{snapshot_name} of volume #{volume_name} - #{snapshot_params.inspect}"
  created_snapshot = @client.volume_snapshots.create(snapshot_params)
  name = created_snapshot.show.name
  while (state = created_snapshot.show.state) == 'pending'
    log "SINGLE VOLUME - Waiting for snapshot '#{name}' to create...state is '#{state}' - #{Time.now.utc}"
    raise "Snapshot creation failed!" if state == "failed"
    sleep 2
  end
end

Timeout::timeout(900) do
  log "SINGLE VOLUME - Unmounting #{actual_device} from #{mount_point}..."
  raise Exception unless system("umount #{mount_point}")
end

log "SINGLE VOLUME - Performing volume detach..."
Timeout::timeout(900) do
  @client.volume_attachments.index(:filter => ["volume_href==#{created_volume.show.href}"]).first.destroy
  while (status = created_volume.show.status) == 'in-use'
    log "SINGLE VOLUME - Waiting for volume '#{created_volume.show.name}' to detach. Status is '#{status}' - #{Time.now.utc}"
    sleep 2
  end
  raise "Volume is not in 'available' state" if status != "available"
end

log "SINGLE VOLUME - destroying volume #{created_volume.show.name}"
parent_href = created_volume.show.href
created_volume.destroy
scan_for_detachments

params[:volume][:parent_volume_snapshot_href] = @client.volume_snapshots.index(:filter => ["parent_volume_href==#{parent_href}"]).first.show.href
params[:volume][:name] = volume_name
params[:volume][:description] = "Restore volume from snapshot"


volume_from_snapshot = nil
Timeout::timeout(900) do
  log "SINGLE VOLUME - Restoring volume from snapshot with params = #{params.inspect}"
  volume_from_snapshot = @client.volumes.create(params)
  # Wait until the volume is successfully created. A volume is said to be created
  # if volume status is "available" or "provisioned".
  name = volume_from_snapshot.show.name
  while (status = volume_from_snapshot.show.status) !~ /^available|provisioned$/
    log "SINGLE VOLUME - Waiting for volume '#{name}' from snapshot '#{created_snapshot.show.name}' to create...current status is '#{status}' - #{Time.now.utc}"
    raise "Creation of volume has failed." if status == "failed"
    sleep 2
  end
end

attachment_params[:volume_attachment][:volume_href] = volume_from_snapshot.show.href

log "SINGLE VOLUME - Requests volume attachment with params = #{attachment_params.inspect}"
# Attach volume and wait until the volume becomes "in-use"
Timeout::timeout(900) do
  attached_volume = @client.volume_attachments.create(attachment_params)
  name = volume_from_snapshot.show.name
  while (state = attached_volume.show.state) != 'attached' && (status = volume_from_snapshot.show.status) != 'in-use'
    log "SINGLE VOLUME - Waiting for volume #{name} to attach... Current state is status is #{status} / #{state} - #{Time.now.utc}"
    sleep 2
  end
  raise "Volume is attached to wrong device" if attached_volume.show.device.inspect.split('"')[1] != device_list(cloud_type).first
  raise "Volume attachment failed" if @client.volume_attachments.index(:filter => ["volume_href==#{volume_from_snapshot.show.href}"]).nil?
  scan_for_attachments
end

log "SINGLE VOLUME - Mount restored device to mount point"
actual_device = (get_current_devices - initial_devices)[0].to_s
scan_for_attachments
log "SINGLE VOLUME - Mounting #{actual_device} at #{mount_point}..."
raise Exception unless system("mount #{actual_device} #{mount_point}")

log "SINGLE VOLUME - Verify the fingerprint of testfile..."
Timeout::timeout(900) do
  r = `md5sum #{testfile}`
  md5_snap = r.split(" ").first
  log "SINGLE VOLUME - md5_snap = #{md5_snap}"
  raise "Signatures don't match. Orig:#{md5_orig}, From Snapshot:#{md5_snap}" unless md5_orig == md5_snap
end

Timeout::timeout(900) do
  log "SINGLE VOLUME - Unmounting restored device #{actual_device} from #{mount_point}..."
  raise Exception unless system("umount #{mount_point}")
end

log "SINGLE VOLUME - Performing volume detach of restored device..."
Timeout::timeout(900) do
  @client.volume_attachments.index(:filter => ["volume_href==#{volume_from_snapshot.show.href}"]).first.destroy
  while (status = volume_from_snapshot.show.status) == 'in-use'
    log "SINGLE VOLUME - Waiting for restored volume '#{volume_from_snapshot.show.name}' to detach. Status is '#{status}' - #{Time.now.utc}"
    sleep 2
  end
  raise "Volume is not in 'available' state" if status != "available"
end

log "SINGLE VOLUME - destroying restored volume #{volume_from_snapshot.show.name}"
volume_from_snapshot.destroy
scan_for_detachments

log "MULTI VOLUME - Requesting multi volumes creation..."
created_volumes = []
Timeout::timeout(900) do
  multi_volume_count.times do |i|
    params[:volume][:name] = volume_name + '_' + i.to_s
    created_volumes << @client.volumes.create(params)
  end
end

created_volumes.each do |vol|
  Timeout::timeout(900) do
    # Wait until the volume is successfully created. A volume is said to be created
    # if volume status is "available" or "provisioned".
    name = vol.show.name
    log "MULTI VOLUME - Checking for creation of volume '#{name}'"
    while (status = vol.show.status) !~ /^available|provisioned$/
      log "MULTI VOLUME - Waiting for volume '#{name}' to create...current status is '#{status}' - #{Time.now.utc}"
      raise "Creation of volume has failed." if status == "failed"
      sleep 2
    end
    log "MULTI VOLUME - volume '#{name}' current status is '#{vol.show.status}'"
  end
end

# Attach multiple volumes and wait until all volumes become "in-use"
created_volumes.each_with_index do |vol, i|
  Timeout::timeout(900) do
    attach_params = {
      :volume_attachment => {
        :device => device_list(cloud_type)[i],
        :instance_href => instance.show.href,
        :volume_href => vol.show.href,
      }
    }

    attachment = @client.volume_attachments.create(attach_params)

    name = vol.show.name
    log "MULTI VOLUME - Requesting attachement of #{name}"
    while (state = attachment.show.state) != 'attached' && (status = vol.show.status) != 'in-use'
      log "MULTI VOLUME - Waiting for volume #{name} to attach...current state / status is #{state} / #{status} - #{Time.now.utc}"
      sleep 2
    end
    raise "Volume attachment failed" if @client.volume_attachments.index(:filter => ["volume_href==#{vol.show.href}"]).nil?
  end
end
scan_for_attachments

# TODO
# LVM, format, mount, create data

log "MULTI VOLUME - Requesting multiple volume backups (volume snapshots)..."
Timeout::timeout(900) do
  attached_volumes = @client.volume_attachments.index(:filter => ["instance_href==#{instance.href}"])

  attached_volumes_hrefs = attached_volumes.map { |attachment| attachment.href }

  params = {
    :backup => {
      :lineage => 'test-vsphere-lineage',
      :name => 'test-vsphere-nickname',
      :volume_attachment_hrefs => attached_volumes_hrefs,
      :description => 'test description'
    }
  }
  multi_vol_snapshot = @client.backups.create(params)
  while (completed = multi_vol_snapshot.show.completed) != true
    log "MULTI VOLUME - Waiting for snapshot to complete...state is '#{completed}' - #{Time.now.utc}"
    sleep 2
  end
end

# TODO
# umount, deconstruct LVM

log "MULTI VOLUME - Performing volumes detach..."
created_volumes.each do |vol|
  Timeout::timeout(900) do
    name = vol.show.name
    @client.volume_attachments.index(:filter => ["volume_href==#{vol.show.href}"]).first.destroy
    while (status = vol.show.status) == 'in-use'
      log "MULTI VOLUME - Waiting for volume '#{name}' to detach. Status is '#{status}' - #{Time.now.utc}"
      sleep 2
    end
    final_state = vol.show.status
    raise "Final state is not 'available': #{final_state}" if final_state != 'available'
  end
end
scan_for_detachments

log "MULTI VOLUME - destroy volumes"
created_volumes.each do |vol|
  vol.destroy
end

# TODO
#log "MULTI VOLUME - destroy snapshots"
