#!/usr/bin/env ruby

require 'optparse'
require 'apipie-bindings'
require 'yaml'
require 'json'
require 'pry'

require './config.rb'


module GlobalDefaultValues
  DEFAULTS={}
  
  def set_default(params={})
    params.each do |key,value|
      DEFAULTS[key]=value
    end
  end

  def default?(key)
    DEFAULTS.key?(key)
  end
  
  def unset_default(key)
    DEFAULTS.delete(key)
  end

  def get_default(key)
    DEFAULTS[key]
  end

  def defaults
    DEFAULTS
  end
end



class ResourceProxy

  include GlobalDefaultValues

  attr_accessor :data, :id

  def initialize(s6api, resource_api, data={})
    @s6api=s6api
    @resource_api=resource_api
    if data.key?('id')
      @id=data['id']
    else
      @id=nil
    end
    if id
      @data=data
      @new_data=Hash.new
    else
      @new_data = data
      @data = data
    end
  end

  def path
    name= @data['name'] or @id or "??"
    "#{@resource_api.path}/#{name}"
  end
  
  def recur_params(pars)
    l=pars.collect do |p|
      par_name = p.name
      if p.respond_to?("params") and p.params != []
        [nm,p.required?,recur_params(p.params)]
      else
        [nm,p.required?,{}]
      end
    end
    Hash[l]
  end
  
  def plural_name
    @resource_api.plural_name
  end

  def singular_name
    @resource_api.singular_name
  end
  
  def save
    if id
      puts "Update id #{id}, name=#{singular_name},mods=#{@new_data}"
      @resource_api.call(:update, :id => id, plural_name => @new_data)
    else
      puts "Create kind=#{singular_name},mods=#{@new_data}"
      @resource_api.call(:create, singular_name => @new_data )
    end
  end

  #def method_missing(m,*args,&block)
  # 
  #end
  
  def to_s
    data['label'] or data['name'] or id.to_s
  end
end



class Collection < ApipieBindings::Resource

  include GlobalDefaultValues

  attr_accessor :plural_name, :singular_name, :s6api, :resource_api
  
  def initialize(s6api, plural_name, singular_name)
    super(plural_name,s6api)
    @s6api = s6api
    @plural_name= plural_name
    @singular_name = singular_name
  end

  def path
    "#{@s6api.path}/#{@plural_name}"
  end
  
  def make_resource_proxy(data)
    ResourceProxy.new(s6api,self,data)
  end

  def list
    index.each do |r|
      puts r.data.to_json
    end
    nil
  end
  
  def method_missing(action_name, action_parameters={})
    action_sym= action_name.to_sym
    #puts "Collection #{plural_name} Action #{action_sym} #{action_parameters}"
    unless has_action?(action_sym)
      return @s6api.send(action_sym,action_parameters)
    end
    req_param= action(action_sym).params.select {|p| p.required? }
    req_param.each do |p|
      k=p.name.to_sym
      unless action_parameters.key?(k)
        if default?(k)
          action_parameters[k]= get_default(k)
        end
      end
    end
    results= call(action_sym,action_parameters)
    #puts results
    if results.key?('results')
      return results['results'].collect {|r|
        make_resource_proxy(r)
      }
    else
      return results
    end
  end

  def _parameters(params)
    ps= params.collect do |p|
      if p.params!=[]
        "#{p.required? ? '*' : ''}#{p.name} => (#{_parameters(p.params)})"
      else
        "#{p.required? ? '*' : ''}#{p.name}"
      end
    end
    ps.join(", ")
  end
  
  def doc
    puts "Actions:"
    puts "--------"
    actions.each do |a|
      puts "#{a.name}(#{_parameters(a.params)}) "
    end
    nil
  end

end

class CollectionSingular < Collection
  def by_id(num,&block)
    res= make_resource_proxy(show(id: num.to_s))
    if res
      if block
        res.instance_eval(&block)
      else
        res
      end
    end
  end
  
  def by(kv={},&block)
    searches=kv.collect {|k,v| "#{k}=\"#{v}\""}
    resource=index(search: searches.first).first
    unless resource
      puts "Creating new #{@kind_singular} with #{k} #{v}"
      resource= make_resource_proxy( { k => v } )
    end
    if block
      return resource.instance_eval(&block)
    else
      return resource
    end
  end
end


class CollectionPlural < Collection
  def filter(f_string,&block)
    index(search: f_string)
  end

end



class S6api < ApipieBindings::API
  include GlobalDefaultValues

  def initialize(config)
    #l=Logger.new(STDERR)
    #l.level=Logger::DEBUG
    #config[:logger]=l
    super(config)
    # create resource collection objects for each resource available in the remote api
    # - singular name version for methods that return single object
    # - plural name version for methods that return a list
    resources.each do |res|
      p_name= res.name.to_s
      s_name= ApipieBindings::Inflector.singularize(res.name.to_s)
      singleton_class.class_eval { attr_accessor p_name }
      singleton_class.class_eval { attr_accessor s_name }
      instance_variable_set('@'+p_name, CollectionPlural.new(self, p_name.to_sym, s_name.to_sym))
      instance_variable_set('@'+s_name, CollectionSingular.new(self, p_name.to_sym, s_name.to_sym))
    end
  end

  # when doing a "cd" in pry, this is what gets printed in the prompt
  def path
    "S6"
  end

  # list the resources
  def doc
    puts "Resources:"
    puts "----------"
    resources.each { |r| puts r.name.to_s; }
    nil
  end

  # wait for task until it ends or <timeout> minutes has passed. Default 10 minutes
  # returns :done, :timeout or :nosuchtask
  def wait_task(task,timeout=10)
    counter=timeout
    if task
      task_id=task['id']
      status=foreman_tasks.show(id: task_id)
      while counter!=0 and status['state']!='stopped'
        #puts "Waiting: state=#{status['state']} result=#{status['result']}"
        sleep(60)
        counter= counter-1
        if counter==0
          return :timeout
        end
        status= foreman_tasks.show(id: task_id)
      end
      # TODO alarm somebody somehow if result is not 'success'
      puts "Done: state=#{status['state']} result=#{status['result']}"
      return :done
    else
      return :nosuchtask
      end
    
  end
  
end



if __FILE__ == $0
  Pry.config.prompt = proc { |obj, nest_level, _| "#{obj.path}:#{nest_level}> " }
  Pry.config.print = proc { |output,value| output.puts value.to_s }
  api=S6api.new(Config::CONNECTIONS[:stdconf])
  api.pry
end
