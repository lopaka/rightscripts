#!/usr/bin/ruby

# add packages: ruby19 rubygems19 ruby19-devel gcc

require 'rubygems'

begin
  gem "right_api_client"
rescue LoadError
  system("gem install right_api_client")
  Gem.clear_paths
end

require 'right_api_client'

def initialize_api_client
  require "/var/spool/cloud/user-data.rb"
  account_id, instance_token = ENV["RS_API_TOKEN"].split(":")
  api_url = "https://#{ENV["RS_SERVER"]}"
  options = {
    :account_id => account_id,
    :instance_token => instance_token,
    :api_url => api_url,
  }

  client = RightApi::Client.new(options)
  client
end

def device_list(cloud_type)
  device = []
  case cloud_type
  when "gce" 
    (1..15).each { |e| device << "persistent-disk-#{e}" }
  when "cloudstack" 
    (1..15).each { |e| device << "device_id:#{e}" }
  when "rackspace-ng"
    ('d'..'z').each { |e| device << "/dev/xvd#{e}" }
  when "azure"
    (0..15).each { |e| device << sprintf('%02d', e) }
  when "openstack" 
    ('c'..'z').each { |e| device << "/dev/vd#{e}" }
  when "ec2" 
    ('j'..'m').each { |e| device << "/dev/sd#{e}" }
    ('d'..'h').each { |e| device << "xvd#{e}" }
  when "vsphere"
    device = ["(create) lsiLogic(0:0)", "(create) lsiLogic(1:0)"]
  end
  device
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
  if File.exist?("/sys/class/scsi_host/host0/scan")
    system("echo '- - -' > /sys/class/scsi_host/host0/scan")
    sleep 5
  end
end

# prevent restclient from logging to screen
RestClient.log = nil

@client = initialize_api_client
instance = @client.get_instance

# define cloud type
cloud_type = (`cat /etc/rightscale.d/cloud`).strip

# set variables
size = cloud_type == "rackspace-ng" ? 100 : 1
volume_name1 = "QTEST VOLUME1"
volume_name2 = "QTEST VOLUME2"
volume_name3 = "QTEST VOLUME3_"
snapshot_name = "QTEST SNAPSHOT"
mount_point = '/mnt/storage'
testfile = mount_point + '/testfile'
md5_snap = nil
md5_orig = nil
volumes_count = 2
    
puts "devices are #{get_current_devices}"
initial_devices = get_current_devices
puts system("cat /proc/partitions")

# Set required parameters
params = {
  :volume => {
    :name => volume_name1,
    :description => "Testing volume/snapshot support",
    :size => size,
  }
}

datacenter_href = instance.links.detect { |link| link["rel"] == "datacenter" }
params[:volume][:datacenter_href] = datacenter_href["href"] if datacenter_href

puts params[:volume][:datacenter_href]

# Some clouds require a volume_type parameter
params[:volume][:volume_type_href] = case cloud_type
when "rackspace-ng"
  raise "Minimum volume size supported by this cloud is 100 GB. Volume size requested #{size.to_s} GB." if size < 100
  
  volume_types = @client.volume_types.index
  volume_type = volume_types.first

  volume_type.href
when 'vsphere'
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
    puts "Found multiple valid volume types"
    puts "Using the volume type with the greatest numeric resource_uid"
    volume_type = volume_types.max_by { |type| type.resource_uid.to_i }
  else
    puts "Found multiple valid volume types"
    puts "Using the first returned valid volume type"
    volume_type = volume_types.first
  end

  if volume_type.size.to_i == 0
    puts "Found volume type that supports custom sizes:" +
      " #{volume_type.name} (#{volume_type.resource_uid})"
  else
    puts "Did not find volume type that supports custom sizes"
    puts "Using closest volume type: #{volume_type.name}" +
      " (#{volume_type.resource_uid}) which is #{volume_type.size} GB"
  end

  volume_type.href

else
  nil
end

puts "Requests volume creation with params = #{params.inspect}"
# Create volume and wait until the volume becomes "available" or "provisioned" (in azure)
created_volume = nil
Timeout::timeout(900) do
  created_volume = @client.volumes.create(params)
  # Wait until the volume is successfully created. A volume is said to be created
  # if volume status is "available" or "provisioned" (in Cloudstack and Azure).
  name = created_volume.show.name
  status = created_volume.show.status
  while status != "available" && status != "provisioned"
    puts "Waiting for volume '#{name}' to create... Current status is '#{status}'"
    raise "Creation of volume has failed." if status == "failed"
    sleep 2
    status = created_volume.show.status
  end
end

attachment_params = {
  :volume_attachment => {
    :device => device_list(cloud_type).first,
    :instance_href => @client.get_instance.show.href,
    :volume_href => created_volume.show.href,
  }
}

puts "Requests volume attachment with params = #{attachment_params.inspect}"
# Attach  volume and wait until the volume becomes "in-use"
attached_volume = nil
Timeout::timeout(900) do
  attached_volume = @client.volume_attachments.create(attachment_params)
  name = created_volume.show.name
  status = created_volume.show.status
  state = attached_volume.show.state
  while state != "attached" && status != "in-use"
    puts "Waiting for volume #{name} to attach... Current state / status is #{state} / #{status}"
    sleep 2
    state = attached_volume.show.state
    status = created_volume.show.status
  end
  raise "Volume is attached to wrong device" if attached_volume.show.device.inspect.split('"')[1] != device_list(cloud_type).first
  raise "Volume attachment is failed" if @client.volume_attachments.index(:filter => ["volume_href==#{created_volume.show.href}"]).nil?
  scan_for_attachments
  puts "attached volume + #{attached_volume.inspect}"
end

puts "Formats the device and mounts it to a mount point"
actual_device = nil
Timeout::timeout(900) do
  scan_for_attachments
  puts "now devices are #{get_current_devices}"
  while get_current_devices.size == initial_devices.size
    puts "Waiting for discovering newly created device..."
    sleep 2
    scan_for_attachments
  end

  actual_device = (get_current_devices - initial_devices)[0].to_s

  puts "Formatting #{actual_device}..."
  puts system("cat /proc/partitions")
  scan_for_attachments
  raise Exception unless system("mkfs.ext3 -F #{actual_device}")

  puts "Mounting #{actual_device} at #{mount_point}..."
  raise Exception unless system("mkdir -p #{mount_point}")
  raise Exception unless system("mount #{actual_device} #{mount_point}")
end

puts "Generates testfile and calculates fingerprint of this file"
Timeout::timeout(900) do
  puts "Generating new testfile..."
  raise "#{testfile} not created" unless system("dd if=/dev/urandom of=#{testfile} bs=16M count=8")
  puts "Calculating fingerprint of testfile..."
  r = `md5sum #{testfile}`
  md5_orig = r.split(" ").first
  puts "md5_origin = #{md5_orig}"
end

snapshot_params = {
  :volume_snapshot => {
    :name => snapshot_name,
    :description => created_volume.show.description,
    :parent_volume_href => created_volume.show.href
  }
}

puts "Takes snapshot from attached volume"
created_snapshot = nil
Timeout::timeout(900) do
  puts "Taking snapshot #{snapshot_name} from volume #{volume_name1}..."
  created_snapshot = @client.volume_snapshots.create(snapshot_params)
  name = created_snapshot.show.name
  while ((state = created_snapshot.show.state) == "pending")
    puts "Waiting for snapshot '#{name}' to create... State is '#{state}'"
    raise "Snapshot creation failed!" if state == "failed"
    sleep 2
  end
end

puts "Unmount device"
Timeout::timeout(900) do
  puts "Unmounting #{actual_device} from #{mount_point}..."
  raise Exception unless system("umount #{mount_point}")
end

puts "Volume #{created_volume.show.name} is '#{created_volume.show.status}'"
puts "Performing volume detach..."
Timeout::timeout(900) do
  status = created_volume.show.status
  @client.volume_attachments.index(:filter => ["volume_href==#{created_volume.show.href}"]).first.destroy
  while status == "in-use"
    puts "Waiting for volume '#{created_volume.show.name}' to detach. Status is '#{status}'..."
    sleep 2
    status = created_volume.show.status
  end
  raise "Volume does not have 'available' state" if status != "available"
end

params[:volume][:parent_volume_snapshot_href] = @client.volume_snapshots.index(:filter => ["parent_volume_href==#{created_volume.show.href}"]).first.show.href
params[:volume][:name] = volume_name2
params[:volume][:description] = "Restore volume from snapshot"

puts "Restores volume from snapshot"
volume_from_snapshot = nil
Timeout::timeout(900) do
  puts "Restoring volume from snapshot with params = #{params.inspect}"
  volume_from_snapshot = @client.volumes.create(params)
  # Wait until the volume is successfully created. A volume is said to be created
  # if volume status is "available" or "provisioned" (in Cloudstack and Azure).
  name = volume_from_snapshot.show.name
  status = volume_from_snapshot.show.status
  while status != "available" && status != "provisioned"
    puts "Waiting for volume '#{name}' from snapshot '#{created_snapshot.show.name}' to create... Current status is '#{status}'"
    raise "Creation of volume has failed." if status == "failed"
    sleep 2
    status = volume_from_snapshot.show.status
  end
end

attachment_params[:volume_attachment][:volume_href] = volume_from_snapshot.show.href

puts "Requests volume attachment with params = #{attachment_params.inspect}"
# Attach  volume and wait until the volume becomes "in-use"
attached_volume2 = nil
Timeout::timeout(900) do
  attached_volume2 = @client.volume_attachments.create(attachment_params)
  puts "------"
  name = volume_from_snapshot.show.name
  status = volume_from_snapshot.show.status
  state = attached_volume2.show.state
  while state != "attached" && status != "in-use"
    puts "Waiting for volume #{name} to attach... Current state is status is #{status} / #{state}"
    sleep 2
    state = attached_volume2.show.state
    status = volume_from_snapshot.show.status
  end
  raise "Volume is attached to wrong device" if attached_volume2.show.device.inspect.split('"')[1] != device_list(cloud_type).first
  raise "Volume attachment is failed" if @client.volume_attachments.index(:filter => ["volume_href==#{volume_from_snapshot.show.href}"]).nil?
  scan_for_attachments
  puts "attached volume + #{attached_volume2.inspect}"
end

puts "Mounts device to a mount point"
actual_device = nil
Timeout::timeout(900) do
  scan_for_attachments
  puts "now devices are #{get_current_devices}"
  while get_current_devices.size == initial_devices.size
    puts "Waiting for discovering newly created device..."
    sleep 2
    scan_for_attachments
  end

  actual_device = (get_current_devices - initial_devices)[0].to_s

  puts system("cat /proc/partitions")
  scan_for_attachments

  puts "Mounting #{actual_device} at #{mount_point}..."
  raise Exception unless system("mount #{actual_device} #{mount_point}")
end

puts "Verify the fingerprint of testfile..."
Timeout::timeout(900) do
  r = `md5sum #{testfile}`
  md5_snap = r.split(" ").first
  puts "md5_snap = #{md5_snap}"
  raise "Signatures don't match. Orig:#{md5_orig}, From Snapshot:#{md5_snap}" unless md5_orig == md5_snap
end


puts "Requesting #{volumes_count-1} volumes creation..."
created_volumes = []
Timeout::timeout(900) do
  (1..volumes_count-1).each do |i|
    params[:volume][:name] = volume_name3 + i.to_s
    created_volumes << @client.volumes.create(params)
  end
end

created_volumes.each do |vol|
  
  Timeout::timeout(900) do
    # Wait until the volume is successfully created. A volume is said to be created
    # if volume status is "available" or "provisioned" (in Cloudstack and Azure).
    name = vol.show.name
    status = vol.show.status
    while status != "available" && status != "provisioned"
      puts "Waiting for volume '#{name}' to create... Current status is '#{status}'"
      raise "Creation of volume has failed." if status == "failed"
      sleep 2
      status = vol.show.status
    end
  end
end

puts "Requests multiple volume attachments..."
# Attach  volumes and wait until the volume becomes "in-use"
attach_volumes = []
created_volumes.each_index do |i|
  
  Timeout::timeout(900) do
    
    attach_params = {
      :volume_attachment => {
        :device => device_list(cloud_type)[i+1],
        :instance_href => @client.get_instance.show.href,
        :volume_href => created_volumes[i].show.href,
      }
    }    
    
    attach_volumes.push(@client.volume_attachments.create(attach_params))
    name = created_volumes[i].show.name
    status = created_volumes[i].show.status
    state = attach_volumes[i].show.state
    puts attach_volumes[i].show.volume.methods
    while state != "attached" && status != "in-use"
      puts "Waiting for volume #{name} to attach... Current state / status is #{state} / #{status}"
      sleep 2
      state = attach_volumes[i].show.state
      status = created_volumes[i].show.status
    end
    raise "Volume attachment is failed" if @client.volume_attachments.index(:filter => ["volume_href==#{created_volumes[i].show.href}"]).nil?
  end
end

puts "Requesting multiple volume backups (volume snapshots)..."
attached_volumes = []
Timeout::timeout(900) do  
  attached_volumes = @client.volume_attachments.index(:filter => ["instance_href==#{instance.href}"])
  
  attached_volume_hrefs = []
  attached_volumes.each do |vol|
    attached_volume_hrefs << vol.href
  end

  params = {
    :backup => {
      :lineage => 'test-vsphere-lineage',
      :name => 'test-vsphere-nickname',
      :volume_attachment_hrefs => attached_volume_hrefs,
      :description => 'test description'
    }
  }
  new_backup = @client.backups.create(params)
end

puts "----------- Cleanup after test ------------"
puts "Unmount device"
Timeout::timeout(900) do
  puts "Unmounting #{actual_device} from #{mount_point}..."
  raise Exception unless system("umount #{mount_point}")
end

puts "Performing volumes detach..."
created_volumes.push(volume_from_snapshot)
created_volumes.each do |vol|
  Timeout::timeout(900) do
    status = vol.show.status
    @client.volume_attachments.index(:filter => ["volume_href==#{vol.show.href}"]).first.destroy
    while status == "in-use"
      puts "Waiting for volume '#{vol.show.name}' to detach. Status is '#{status}'..."
      sleep 2
      status = vol.show.status
    end
    raise "Volume does not have 'available' state" if status != "available"
  end
end

puts "Removes snapshot #{created_snapshot.show.name}"
Timeout::timeout(900) do
  name = created_snapshot.show.name
  resource_uid = created_snapshot.show.resource_uid
  puts "Removing volume snapshot..."
  @client.volume_snapshots.index(:filter => ["resource_uid==#{resource_uid}"]).first.destroy
  sleep 2
  begin
    while !@client.volume_snapshots.index(:filter => ["resource_uid==#{resource_uid}"]).nil? 
      puts "Waiting for snapshot '#{name}' to delete. State is '#{created_snapshot.show.state}'..."     
      sleep 2
    end
  rescue Exception => e
    puts "Snapshot #{name} has been deleted"
  end
end

puts "Removes backups..."
attached_volumes.each do |vol|
  
  Timeout::timeout(900) do
    href = vol.show.volume.show.href
    name = @client.volume_snapshots.index(:filter => ["parent_volume_href==#{href}"]).first.show.name
    puts "Removing volume snapshots #{name}..."
    @client.volume_snapshots.index(:filter => ["parent_volume_href==#{href}"]).first.destroy
    sleep 2
    begin
      while !@client.volume_snapshots.index(:filter => ["parent_volume_href==#{href}"]).nil? 
        puts "Waiting for snapshot '#{name}' to delete. State is '#{@client.volume_snapshots.index(:filter => ["parent_volume_href==#{href}"]).first.show.state}'..."     
        sleep 2
      end
    rescue Exception => e
      puts "Snapshot #{name} has been deleted"
    end
  end

end

puts "Removes volumes..."
created_volumes.push(created_volume)
created_volumes.each do |vol|
  Timeout::timeout(900) do
    name = vol.show.name
    puts "Removing volume #{name}..."
    begin
      @client.volumes.index(:filter => ["name==#{name}"]).first.destroy
    rescue Exception => e
      retry
    end
    begin
      while !@client.volumes.index(:filter => ["name==#{name}"]).nil?
        puts "Waiting for volume '#{name}' to delete. Status is '#{vol.show.status}'..."
        sleep 2
      end
    rescue Exception => e
      puts "Volume #{name} has been deleted"
    end
  end
end

