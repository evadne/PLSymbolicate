# 
# Author: Jonas Witt <jonas@metaquark.de>
# 
# Copyright (c) 2011 metaquark
# All rights reserved.
# 
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
# 

# requires:
# sudo gem install ruby_protobuf spotlight plist

require 'rubygems'
require 'protobuf/message/message'
require 'protobuf/message/enum'
require 'protobuf/message/service'
require 'protobuf/message/extend'
require 'spotlight'

if ARGV.size == 0
  puts "usage: plsymbolicate.rb <plcrashlog> [binary_path]"
  Kernel.exit 1
end

module Plcrash
  ::Protobuf::OPTIONS[:"java_package"] = "com.plausiblelabs.crashreporter"
  class Architecture < ::Protobuf::Enum
    defined_in __FILE__
    X86_32 = value(:X86_32, 0)
    X86_64 = value(:X86_64, 1)
    ARM = value(:ARM, 2)
    PPC = value(:PPC, 3)
    PPC64 = value(:PPC64, 4)
  end
  class OperatingSystem < ::Protobuf::Enum
    defined_in __FILE__
    MAC_OS_X = value(:MAC_OS_X, 0)
    IPHONE_OS = value(:IPHONE_OS, 1)
    IPHONE_SIMULATOR = value(:IPHONE_SIMULATOR, 2)
  end
  class CrashReport < ::Protobuf::Message
    defined_in __FILE__
    class SystemInfo < ::Protobuf::Message
      defined_in __FILE__
      required :OperatingSystem, :operating_system, 1
      required :string, :os_version, 2
      required :Architecture, :architecture, 3
      required :uint32, :timestamp, 4
    end
    required :SystemInfo, :system_info, 1
    class ApplicationInfo < ::Protobuf::Message
      defined_in __FILE__
      required :string, :identifier, 1
      required :string, :version, 2
    end
    required :ApplicationInfo, :application_info, 2
    class Thread < ::Protobuf::Message
      defined_in __FILE__
      required :uint32, :thread_number, 1
      class StackFrame < ::Protobuf::Message
        defined_in __FILE__
        required :uint64, :pc, 3
      end
      repeated :StackFrame, :frames, 2
      required :bool, :crashed, 3
      class RegisterValue < ::Protobuf::Message
        defined_in __FILE__
        required :string, :name, 1
        required :uint64, :value, 2
      end
      repeated :RegisterValue, :registers, 4
    end
    repeated :Thread, :threads, 3
    class BinaryImage < ::Protobuf::Message
      defined_in __FILE__
      required :uint64, :base_address, 1
      required :uint64, :size, 2
      required :string, :name, 3
      optional :bytes, :uuid, 4
    end
    repeated :BinaryImage, :binary_images, 4
    class Exception < ::Protobuf::Message
      defined_in __FILE__
      required :string, :name, 1
      required :string, :reason, 2
    end
    optional :Exception, :exception, 5
    class Signal < ::Protobuf::Message
      defined_in __FILE__
      required :string, :name, 1
      required :string, :code, 2
      required :uint64, :address, 3
    end
    required :Signal, :signal, 6
  end
end

file_content = File.open(ARGV[0], 'rb') { |file| file.read }

protobuf_data = file_content[8..-1]

report = Plcrash::CrashReport.new
report.parse_from_string protobuf_data

platform_dir = Spotlight::Query.new("kMDItemDisplayName = 'iPhoneOS.platform'").execute
if platform_dir.size > 0
  platform_dir = File.join(platform_dir[0].get(:kMDItemPath), 'DeviceSupport', "#{report.system_info.os_version}*")
  m = Dir.glob(platform_dir)
  if m.size > 0
    $os_symbols_dir = File.join(m[0], 'Symbols')
    puts "OS Symbols:   #{$os_symbols_dir}"
  else
    puts "Warning: Could not find iPhone symbols for iOS #{report.system_info.os_version}"
  end
end

$local_path_for_image = {}

def extend_path(image_path)
  if image_path.end_with? '.xcarchive'
    b = "#{image_path}/dSYMs/"
    image_path = b + Dir.entries(b)[2]
  end
  if image_path.end_with? '.dSYM'
    b = "#{image_path}/Contents/Resources/DWARF/"
    image_path = b + Dir.entries(b)[2]
  end
  image_path
end

def converted_uuid(img)
  img_uuid = img.uuid.unpack('H32')[0]
  "#{img_uuid[0..7].upcase}-#{img_uuid[8..11].upcase}-#{img_uuid[12..15].upcase}-#{img_uuid[16..19].upcase}-#{img_uuid[20..32].upcase}"  
end

def get_local_path_for_image(img)
  if $local_path_for_image.has_key? img.name
    return $local_path_for_image[img.name]
  end
  
  os_path = File.join($os_symbols_dir, img.name)
  if File.exists? os_path
    image_path = os_path
  else
    img_uuid = converted_uuid img
  
    image_files = Spotlight::Query.new("com_apple_xcode_dsym_uuids = '#{img_uuid}'").execute
    if image_files.size == 0
      image_path = ''
    else
      image_path = image_files[0].get(:kMDItemPath)
      image_path = extend_path(image_path)
    end
  end
  
  $local_path_for_image[img.name] = image_path
  image_path
end

app_img = report.binary_images[0]
if ARGV.size > 1
  image_path = ARGV[1]
  if image_path[0..0] != '/'
    image_path = File.join(Dir.getwd, image_path)
  end
  image_path = extend_path image_path
  $local_path_for_image[app_img.name] = image_path
else
  image_path = get_local_path_for_image(app_img)
  if image_path == ''
    puts "Warning: Couldn't find image with UUID #{img_uuid}"
    Kernel.exit 1
  end
end
puts "App Image:    #{image_path}"

puts "Identifier:   #{report.application_info.identifier}"
puts "Version:      #{report.application_info.version}"

crash_arch = nil
app_img_uuid = converted_uuid app_img
['armv6', 'armv7'].each { |arch| 
  if /uuid ([A-F0-9\-]{36})/ =~ IO.popen("otool -arch #{arch} -l \"#{image_path}\"") { |p| p.read }
    if app_img_uuid == Regexp.last_match(1)
      crash_arch = arch
      break
    end
  end
}
if not crash_arch
  puts "Warning: could not detect crash log architecture"
  Kernel.exit 1
end

jailbreak_indicators = [/CydiaSubstrate\.framework/]
has_jailbreak = false
report.binary_images.each { |img|
  jailbreak_indicators.each { |re|
    if re =~ img.name
      has_jailbreak = true
      break
    end
  }
}
if has_jailbreak
  puts ""
  puts "WARNING: Jailbreak detected!"
end

if report.exception
  puts ""
  puts "Exception Name: #{report.exception.name}"
  puts "Exception Reason: #{report.exception.reason}"
end

puts ""
puts "Architecture: #{crash_arch}"

if report.signal
  puts ""
  puts "Exception Type:  #{report.signal.name}"
  puts "Exception Codes: #{report.signal.code} at #{report.signal.address}"
end

puts ""

report.threads.each do |thread|
  if not thread.crashed
    next
  end
  
  puts "Tread #{thread.thread_number} Crashed:"
  frame_index = 0
  thread.frames.each do |frame|
    frame_img = nil
    report.binary_images.each { |img|
      if frame.pc <= img.base_address + img.size and frame.pc >=  img.base_address
        frame_img = img
        break
      end
    }

    signature = "0x%08x" % frame.pc
    load = "0x%08x" % frame_img.base_address
    
    info = ''
    image_path = get_local_path_for_image frame_img
    if image_path != ''
      info = IO.popen("atos -arch #{crash_arch} -o \"#{image_path}\" -l #{load} #{signature}") { |p| p.read.strip }  
    end
    if info == signature
      info = ''
    end

    puts "#{frame_index.to_s.ljust(3)} #{File.split(frame_img.name)[1].ljust(32)} #{signature} #{info}"    
    
    frame_index += 1
  end
  puts ""
end

