
require 'rubygems'
require 'echoe'
require 'lib/has_many_polymorphs/rake_task_redefine_task'

Echoe.new("has_many_polymorphs") do |p|  
  p.project = "fauna"
  p.summary = "An ActiveRecord plugin for defining self-referential polymorphic associations."
  p.url = "http://blog.evanweaver.com/pages/code#polymorphs"  
  p.docs_host = "blog.evanweaver.com:~/www/snax/public/files/doc/"  
  p.extra_deps = ["activerecord"]
  p.rdoc_pattern = /polymorphs\/association|polymorphs\/class_methods|polymorphs\/reflection|README|CHANGELOG|TODO|LICENSE/    
end

desc 'Run the test suite.'
Rake::Task.redefine_task("test") do
   puts "Warning! Tests must be run with the plugin installed in a functioning Rails\nenvironment."
   system "ruby -Ibin:lib:test test/unit/polymorph_test.rb #{ENV['METHOD'] ? "--name=#{ENV['METHOD']}" : ""}"
end