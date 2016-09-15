require 'apipie-bindings'
require 'yaml'
require 'json'



DEFAULTS={}

def set_default(params={})
  params.each do |key,value|
    if value==nil
      DEFAULTS.delete(key.to_s)
    else
      DEFAULTS[key.to_s]=value
    end
  end
end

def stringify_keys_deep(h)
  case h
  when Hash
    newh= Hash[
      h.map do |k, v|
        [ k.respond_to?(:to_s) ? k.to_s : k, stringify_keys_deep(v) ]
      end
    ]
  when Enumerable
    h.map { |v| stringify_keys_deep(v) }
  else
    h
  end
end
  

  

class KV
  attr_accessor :data, :resource
  
  def initialize(importdata={},resource)
    @resource=resource
    @data=stringify_keys_deep(importdata)
    #puts resource.action(:update).params
    if resource.has_action? :update
      pars= resource.action(:update).params
      res_par = pars.find { |p| p.name == resource.singular_name.to_s }
      if res_par
        # update wants <resource class name> parameters
        @attr_settable_names= res_par.params.collect {|p| p.name.to_s}
      else
        # update has the resource class parameters there directly
        @attr_settable_names= pars.collect{|p| p.name.to_s}
      end
    else
      @attr_settable_names= []
    end
    #puts @attr_settable_names
  end
  
  def method_missing(msym,*args,&block)
    mname=msym.to_s
    if resource.has_action?(msym)
      sname = resource.singular_name
      action=resource.action(msym)
      args= rewrite_args(data,action.params,sname)
      res=action.call(args)
      res.key?('results') ? res['results'].collect{|r| KV.new(r,resource)} : KV.new(res,resource)
    elsif mname =~ /^(\w+)=$/
      #setter
      if @attr_settable_names.include?($1)
        @data[$1]= recursive_stringify_keys(args[0])
      else
        raise ArgumentError.new("You cannot set attribute #{mname} of resource type #{resource.singular_name}. Acceptable values #{@attr_settable_values}")
      end
    elsif mname =~ /^(\w+)$/
      @data[$1]
    end
  end
  
  
  def to_s
    @data.to_s
  end

end



module MyEnum
  #
  def map(&block)
    result= []
    each do |r|
      result << block.call(r)
    end
    result
  end
  
  def find(ifnone = nil, &block)
    result = nil
    found = false
    each do |element|
      if block.call(element)
        result = element
        found = true
        break
      end
    end
    found ? result : ifnone && ifnone.call
  end
  
  def find_all(&block)
    result = []
    each do |element|
      if block.call(element)
        result << element
      end
    end
    result
  end

  def collect(&block)
    result=[]
    each do |element|
      result << block.call(element)
    end
    result
  end
    
  def first
    found = nil
    each do |element|
      found = element
      break
    end
    found
  end

  def reduce(accumulator = nil, operation = nil, &block)
    if accumulator.nil? && operation.nil? && block.nil?
      raise ArgumentError, "you must provide an operation or a block"
    end 
    if operation && block
      raise ArgumentError, "you must provide either an operation symbol or a block, not both"
    end
    if operation.nil? && block.nil?
      operation = accumulator
      accumulator = nil
    end
    
    block = case operation
            when Symbol
              lambda { |acc, value| acc.send(operation, value) }
            when nil
              block
            else
              raise ArgumentError, "the operation provided must be a symbol"
            end
    
    if accumulator.nil?
      ignore_first = true
      accumulator = first
    end
    idx = 0
    #
    each do |element|
      unless ignore_first && idx == 0
        accumulator = block.call(accumulator, element)
      end
      idx += 1
    end
    accumulator
  end
end



module ApiHelpers
  include MyEnum
  
  def _parameter_doc(params)
    ps= params.collect do |p|
      if p.params!=[]
        "#{p.required? ? '*' : ''}#{p.name} => (#{_parameter_doc(p.params)})"
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
      puts "#{a.name}(#{_parameter_doc(a.params)}) "
    end
    nil
  end
  
  def by(kv={})
    each.find do |r|
      #puts r.to_json
      res=true
      kv.each do |k,v|
        #puts "test #{k} == #{v}"
        unless r.data.key?(k.to_s) and r.data[k.to_s]==v
          res=false
        end
      end
      res
    end
  end

  def each(&block)
    index.each(&block)
  end

  def ==(other)
    index == other
  end
  
end

def rewrite_args(args,params,sname)
  result={}
  params.each do |par|
    pname=par.name.to_s
    #puts "Looking for parameter #{par.name} #{par.name.class} #{par.expected_type}"
    if pname.to_s == sname.to_s
      result[pname]= rewrite_args(sargs, par.params, sname)
      #puts "...name of the resource"
    elsif DEFAULTS.key?(pname)
      result[pname]=DEFAULTS[pname]
      #puts "...found in defaults #{DEFAULTS[par.name]}"
    elsif args.key?(pname)
      result[pname]=args[pname]
      #puts "...found in arguments"
    elsif par.required?
      raise ArgumentError.new("Value for the required parameter #{pname} could not be found")
    end
    #puts result
  end
  result
end
  



class S6api < ApipieBindings::API
  
  def initialize(config)
    super(config)
    # === Synthesize the resource/action paths as methods ===
    # monkey see, monkey patch
    #
    resources.each do |resource|
      resource.actions.each do |action|
        # inject to resource methods that return action
        resource.define_singleton_method(action.name.to_s) do |args={}|
          sname = ApipieBindings::Inflector.singularize(resource.to_s)
          args= stringify_keys_deep(args)
          args= rewrite_args(args,action.params,sname.to_s)
          #puts "Call #{resource.name}.#{action.name} #{args}"
          res=action.call(args)
          res.key?('results') ? res['results'].collect{|r| KV.new(r,resource)} : KV.new(res,resource)
        end
      end
      # inject method that returns the resource object
      define_singleton_method(resource.name.to_s) {resource}
      define_singleton_method(resource.singular_name.to_s) {resource}
      # add helpful methods
      resource.instance_eval do
        extend ApiHelpers
      end
    end
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
    #puts task.data
    if task
      status=foreman_tasks.show('id'=> task.id)
      #puts status.data
      while counter!=0 and status.state != 'stopped'
        puts "#{counter}: #{status.progress} #{status.state} #{status.result}"
        sleep(60)
        counter= counter-1
        if counter==0
          return :timeout
        end
        status= foreman_tasks.show('id'=> task.id)
      end
      # TODO alarm somebody somehow if result is not 'success'
      puts "Done: state=#{status.state} result=#{status.result}"
      return :done
    else
      return :nosuchtask
      end  
  end
  
end


