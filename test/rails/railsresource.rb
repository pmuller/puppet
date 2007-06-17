#!/usr/bin/env ruby

$:.unshift("../lib").unshift("../../lib") if __FILE__ =~ /\.rb$/

require 'puppet'
require 'puppet/rails'
require 'puppettest'
require 'puppettest/railstesting'
require 'puppettest/resourcetesting'

# Don't do any tests w/out this class
if Puppet.features.rails?
class TestRailsResource < Test::Unit::TestCase
    include PuppetTest::RailsTesting
    include PuppetTest::ResourceTesting

    def setup
        super
        railsinit
    end

    def teardown
        railsteardown
        super
    end

    def mktest_resource
        # We need a host for resources
        host = Puppet::Rails::Host.new(:name => "myhost")

        # Now build a resource
        resource = host.resources.create(
            :title => "/tmp/to_resource", 
            :restype => "file",
            :exported => true)

        # Now add some params
        params.each do |param, value|
            pn = Puppet::Rails::ParamName.find_or_create_by_name(param)
            pv = resource.param_values.create(:value => value,
                                              :param_name => pn)
        end

        host.save

        return resource
    end
    
    def params
        {"owner" => "root", "mode" => "644"}
    end

    # Create a resource param from a rails parameter
    def test_to_resource
        resource = mktest_resource

        # We need a scope
        interp, scope, source = mkclassframing

        # Find the new resource and include all it's parameters.
        resource = Puppet::Rails::Resource.find_by_id(resource.id)

        # Now, try to convert our resource to a real resource
        res = nil
        assert_nothing_raised do
            res = resource.to_resource(scope)
        end
        assert_instance_of(Puppet::Parser::Resource, res)
        assert_equal("root", res[:owner])
        assert_equal("644", res[:mode])
        assert_equal("/tmp/to_resource", res.title)
        assert_equal(source, res.source)
    end

    def test_parameters
        resource = mktest_resource
        setparams = nil
        assert_nothing_raised do
            setparams = resource.parameters.inject({}) { |h, a|
                h[a[0]] = a[1][0]
                h
            }
        end
        assert_equal(params, setparams,
            "Did not get the right answer from #parameters")
    end

    # Make sure we can retrieve individual parameters by name.
    def test_parameter
        resource = mktest_resource

        params.each do |p,v|
            assert_equal(v, resource.parameter(p), "%s is not correct" % p)
        end
    end
end
else
    $stderr.puts "Install Rails for Rails and Caching tests"
end

# A separate class for testing rails integration
class TestExportedResources < PuppetTest::TestCase
	include PuppetTest
    include PuppetTest::ParserTesting
    include PuppetTest::ResourceTesting
    include PuppetTest::RailsTesting
    Parser = Puppet::Parser
    AST = Parser::AST
    Reference = Puppet::Parser::Resource::Reference

    def setup
        super
        Puppet[:trace] = false
        @interp, @scope, @source = mkclassframing
    end

    confine "Missing rails support" => Puppet.features.rails?

    # Compare a parser resource to a rails resource.
    def compare_resources(host, res, updating, options = {})
        # to_rails now expects to be passed a resource, else it will create a new one
        newobj = host.resources.find_by_restype_and_title(res.type, res.title)
        assert_nothing_raised do
            #newobj = res.to_rails(host, newobj)
            newobj = res.to_rails(host)
        end

        assert_instance_of(Puppet::Rails::Resource, newobj)
        newobj.save

        if updating
            tail = "on update"
        else
            tail = ""
        end

        # Make sure we find our object and only our object
        count = 0
        obj = nil
        Puppet::Rails::Resource.find(:all).each do |obj|
            assert_equal(newobj.id, obj.id, "Found object has a different id than generated object %s" % tail)
            count += 1
            [:title, :restype, :line, :exported].each do |param|
                if param == :restype
                    method = :type
                else
                    method = param
                end
                assert_equal(res.send(method), obj[param], 
                    "attribute %s was not set correctly in rails %s" % [param, tail])
            end
        end
        assert_equal(1, count, "Got too many resources %s" % tail)
        # Now make sure we can find it again
        assert_nothing_raised do
            obj = Puppet::Rails::Resource.find_by_restype_and_title(
                res.type, res.title, :include => :param_names
            )
        end
        assert_instance_of(Puppet::Rails::Resource, obj)

        # Make sure we get the parameters back
        params = options[:params] || [obj.param_names.collect { |p| p.name },
            res.to_hash.keys].flatten.collect { |n| n.to_s }.uniq

        params.each do |name|
            param = obj.param_names.find_by_name(name)
            if res[name]
                assert(param, "resource did not keep %s %s" % [name, tail])
            else
                assert(! param, "resource did not delete %s %s" % [name, tail])
            end
            if param
                values = param.param_values.collect { |pv| pv.value }
                should = res[param.name]
                should = [should] unless should.is_a?(Array)
                assert_equal(should, values,
                    "%s was different %s" % [param.name, tail])
            end
        end
    end

    def test_to_rails
        railsteardown
        railsinit
        ref1 = Reference.new :type => "exec", :title => "one"
        ref2 = Reference.new :type => "exec", :title => "two"
        res = mkresource :type => "file", :title => "/tmp/testing",
            :source => @source, :scope => @scope,
            :params => {:owner => "root", :source => ["/tmp/A", "/tmp/B"],
                :mode => "755", :require => [ref1, ref2]}

        res.line = 50

        # We also need a Rails Host to store under
        host = Puppet::Rails::Host.new(:name => Facter.hostname)

        compare_resources(host, res, false, :params => %w{owner source mode})

        # Now make some changes to our resource.  We're removing the mode,
        # changing the source, and adding 'check'.
        res = mkresource :type => "file", :title => "/tmp/testing",
            :source => @source, :scope => @scope,
            :params => {:owner => "bin", :source => ["/tmp/A", "/tmp/C"],
            :check => "checksum"}

        res.line = 75
        res.exported = true

        compare_resources(host, res, true, :params => %w{owner source mode check})

        # Now make sure our parameters did not change
        assert_instance_of(Array, res[:require], "Parameter array changed")
        res[:require].each do |ref|
            assert_instance_of(Reference, ref, "Resource reference changed")
        end
    end
end

# $Id$

