=begin
    Copyright 2010-2012 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

require 'em-synchrony'

module Arachni

lib = Options.dir['lib']
require lib + 'framework'
require lib + 'rpc/server/spider'
require lib + 'rpc/server/module/manager'
require lib + 'rpc/server/plugin/manager'

module RPC
class Server

#
# Wraps the framework of the local instance and the frameworks of all
# its slaves (when in High Performance Grid mode) into a neat, little,
# easy to handle package.
#
# Disregard all:
# * 'block' parameters, they are there for internal processing
#   reasons and cannot be accessed via the API
# * inherited methods and attributes
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Framework < ::Arachni::Framework
    require Options.dir['lib'] + 'rpc/server/distributor'

    include Utilities
    include Distributor

    # make this inherited methods visible again
    private :audit_store, :stats, :paused?, :lsmod, :lsplug, :version, :revision,
            :status, :clean_up!
    public  :audit_store, :stats, :paused?, :lsmod, :lsplug, :version, :revision,
            :status, :clean_up!

    alias :old_clean_up :clean_up
    alias :auditstore   :audit_store

    private :old_clean_up

    def initialize( opts )
        super( opts )

        # already inherited but lets make it explicit
        @opts = opts

        @modules = Module::Manager.new( self )
        @plugins = Plugin::Manager.new( self )
        @spider  = Spider.new( self )

        # holds all running instances
        @instances = []

        # if we're a slave this var will hold the URL of our master
        @master_url = ''

        # some methods need to be accessible over RPC for instance management,
        # restricting elements, adding more pages etc.
        #
        # however, when in HPG mode, the master should not be tampered with,
        # so we generate a local token (which is not known to API clients)
        # to be used server side by self to facilitate access control
        @local_token = gen_token

        @override_sitemap = Set.new

        @element_ids_per_page = {}
    end

    #
    # Returns true if the system is scanning, false if {#run} hasn't been called yet or
    # if the scan has finished.
    #
    # @param    [Bool]  include_slaves  take slave status into account too?
    #                                     If so, it will only return false if slaves
    #                                     are done too.
    #
    # @param    [Proc]  block          block to which to pass the result
    #
    def busy?( include_slaves = true, &block )
        busyness = [ extended_running? ]

        if @instances.empty? || !include_slaves
            block.call( busyness[0] )
            return
        end

        foreach = proc do |instance, iter|
            instance.framework.busy? { |res| iter.return( res ) }
        end
        after = proc do |res|
            busyness << res
            busyness.flatten!
            block.call( busyness.include?( true ) )
        end

        map_slaves( foreach, after )
    end

    #
    # @return  [Array<Hash>]  information about all available plug-ins
    #
    def lsplug
        super.map do |plugin|
            plugin[:options] = [plugin[:options]].flatten.compact.map do |opt|
                opt.to_h.merge( 'type' => opt.type )
            end
            plugin
        end
    end

    def set_as_master
        @opts.grid_mode = 'high_performance'
    end

    #
    #
    # @return   [Bool]    true if running in HPG (High Performance Grid) mode
    #                       and instance is the master, false otherwise.
    #
    def master?
        @opts.grid_mode == 'high_performance'
    end
    alias :high_performance? :master?

    def slave?
        !!@master
    end

    def solo?
        !master? && !slave?
    end

    def enslave( instance_info, opts = {}, &block )
        fail "Instance info does not contain a 'url' key."   if !instance_info['url']
        fail "Instance info does not contain a 'token' key." if !instance_info['token']

        # since we have slaves we must be a master...
        set_as_master

        instance = connect_to_instance( instance_info )
        instance.opts.set( cleaned_up_opts ) do
            instance.framework.set_master( self_url, @opts.datastore[:token] ) do
                @instances << instance_info
                block.call true if block_given?
            end
        end
    end

    #
    # Starts the audit.
    #
    # @return   [Bool]  false if already running, true otherwise
    #
    def run
        # return if we're already running
        return false if extended_running?

        @extended_running = true

        #
        # if we're in HPG mode do fancy stuff like distributing and balancing workload
        # as well as starting slave instances and deal with some lower level
        # operations of the local instance like running plug-ins etc...
        #
        # otherwise just run the local instance, nothing special...
        #
        if master?

            ::Thread.new {

                #
                # We're in HPG (High Performance Grid) mode,
                # things are going to get weird...
                #

                # we'll need analyze the pages prior to assigning
                # them to each instance at the element level so as to gain
                # more granular control over the assigned workload
                #
                # put simply, we'll need to perform some magic in order
                # to prevent different instances from auditing the same elements
                # and wasting bandwidth
                #
                # for example: search forms, logout links and the like will
                # most likely exist on most pages of the site and since each
                # instance is assigned a set of URLs/pages to audit they will end up
                # with common elements so we have to prevent instances from
                # performing identical checks.
                #
                # interesting note: should previously unseen elements dynamically
                # appear during the audit they will override these restrictions
                # and each instance will audit them at will.
                #

                # prepare the local instance (runs plugins and starts the timer)
                prepare

                # we need to take our cues from the local framework as some
                # plug-ins may need the system to wait for them to finish
                # before moving on.
                sleep( 0.2 ) while paused?

                each = proc do |d_url, iterator|
                    d_opts = {
                        'rank'   => 'slave',
                        'target' => @opts.url,
                        'master' => self_url
                    }

                    connect_to_dispatcher( d_url ).dispatch( self_url, d_opts ) do |instance_hash|
                        enslave( instance_hash ){ |b| iterator.next }
                    end
                end

                after = proc do
                    @status = :crawling

                    spider.on_each_page do |page|
                        update_element_ids_per_page( { page.url => build_elem_list( page ) },
                                                     @local_token )
                        @override_sitemap << page.url
                    end

                    #@start_time = Time.now
                    #ap 'PRE CRAWL'
                    # start the crawl and extract all paths
                    spider.on_complete do
                        #ap 'POST CRAWL'

                        #puts "---- Found #{spider.sitemap.size} URLs in #{Time.now - @start_time} seconds."

                        element_ids_per_page = @element_ids_per_page

                        @override_sitemap |= spider.sitemap

                        #ap 'SITEMAP'
                        #ap @override_sitemap.to_a

                        @status = :distributing
                        # the plug-ins may have updated the page queue
                        # so we need to distribute these pages as well
                        page_a = []
                        while !@page_queue.empty? && page = @page_queue.pop
                            page_a << page
                            @override_sitemap << page.url
                            element_ids_per_page[page.url] |= build_elem_list( page )
                        end

                        #ap 'INSTANCES'
                        #ap self_url
                        #ap @instances

                        # split the URLs of the pages in equal chunks
                        chunks    = split_urls( element_ids_per_page.keys, @instances.size + 1 )
                        chunk_cnt = chunks.size

                        #ap 'ELEMENT IDS PER PAGE'
                        #ap element_ids_per_page.keys

                        #ap "CHUNK COUNT: #{chunk_cnt}"
                        if chunk_cnt > 0
                            # split the page array into chunks that will be distributed
                            # across the instances
                            page_chunks = page_a.chunk( chunk_cnt )

                            # assign us our fair share of plug-in discovered pages
                            update_page_queue( page_chunks.pop, @local_token )

                            # remove duplicate elements across the (per instance) chunks
                            # while spreading them out evenly
                            elements = distribute_elements( chunks, element_ids_per_page )

                            # restrict the local instance to its assigned elements
                            restrict_to_elements( elements.pop, @local_token )

                            # set the URLs to be audited by the local instance
                            @opts.restrict_paths = chunks.pop

                            chunks.each_with_index do |chunk, i|
                                # spawn a remote instance, assign a chunk of URLs
                                # and elements to it and run it
                                configure_and_run( @instances[i],
                                                   urls:     chunk,
                                                   elements: elements.pop,
                                                   pages:    page_chunks.pop
                                )
                            end
                        end

                        # start the local instance
                        Thread.new {
                            #ap 'AUDITING'
                            audit

                            #ap 'OLD CLEAN UP'
                            old_clean_up

                            #ap 'DONE'
                            @extended_running = false
                            @status = :done
                            #ap '+++++++++++++++'
                        }
                    end

                    spider.update_peers( @instances ){ spider.run }
                end

                # get the Dispatchers with unique Pipe IDs
                # in order to take advantage of line aggregation
                preferred_dispatchers do |pref_dispatchers|
                    iterator_for( pref_dispatchers ).each( each, after )
                end

            }
        else
            # start the local instance
            Thread.new {
                #ap 'AUDITING'
                super
                #ap 'DONE'
                @extended_running = false
            }
        end

        true
    end

    #
    # If the scan needs to be aborted abruptly this method takes care of
    # any unfinished business (like running plug-ins).
    #
    # Should be called before grabbing the {#auditstore}, especially when
    # running in HPG mode as it will take care of merging the plug-in results
    # of all instances.
    #
    # @param    [Proc]  block  block to be called once the cleanup has finished
    #
    def clean_up( &block )
        super( true )

        if @instances.empty?
            block.call( true ) if block_given?
            return
        end

        foreach = proc do |instance, iter|
            instance.framework.clean_up {
                instance.plugins.results do |res|
                    iter.return( !res.rpc_exception? ? res : nil )
                end
            }
        end
        after = proc { |results| @plugins.merge_results( results.compact ); block.call( true ) }
        map_slaves( foreach, after )
    end

    #
    # Pauses the running scan on a best effort basis.
    #
    def pause
        super
        each_slave{ |instance, iter| instance.framework.pause{ iter.next } }
        true
    end
    alias :pause! :pause

    #
    # Resumes a paused scan right away.
    #
    def resume
        super
        each_slave { |instance, iter| instance.framework.resume{ iter.next } }
        true
    end
    alias :resume! :resume

    #
    # Merged output of all running instances.
    #
    # This is going probably to be wildly out of sync and lack A LOT of messages.
    #
    # It's here to give the notion of scan progress to the end-user rather than
    # provide an accurate depiction of the actual progress.
    #
    # The returned object will be in the form of:
    #
    #   [ { <type> => <message> } ]
    #
    # like:
    #
    #   [
    #       { status: 'Initiating'},
    #       {   info: 'Some informational msg...'},
    #   ]
    #
    # Possible message types are:
    # * status  -- Status messages, usually to denote progress.
    # * info  -- Informational messages, like notices.
    # * ok  -- Denotes a successful operation or a positive result.
    # * verbose -- Verbose messages, extra information about whatever.
    # * bad  -- Opposite of :ok, an operation didn't go as expected,
    #   something has failed but it's recoverable.
    # * error  -- An error has occurred, this is not good.
    # * line  -- Generic message, no type.
    #
    # @param    [Proc]  block  block to which to pass the result
    #
    # @return   [Array<Hash>]
    #
    def output( &block )
        buffer = flush_buffer

        if @instances.empty?
            block.call( buffer )
            return
        end

        foreach = proc do |instance, iter|
            instance.service.output { |out| iter.return( out ) }
        end
        after = proc { |out| block.call( (buffer | out).flatten ) }
        map_slaves( foreach, after )
    end

    #
    # Returns aggregated progress data and helps to limit the amount of calls
    # required in order to get an accurate depiction of a scan's progress and includes:
    # * output messages
    # * discovered issues
    # * overall statistics
    # * overall scan status
    # * statistics of all instances individually
    #
    # @param    [Hash]  opts    contains info about what data to return:
    #                             * :messages -- include output messages
    #                             * :slaves   -- include slave data
    #                             * :issues   -- include issue summaries
    #                             Uses an implicit include for the above (i.e. nil will be considered true).
    #
    #                             * :as_hash  -- if set to true will convert issues to hashes before returning
    #
    # @param    [Proc]  block  block to which to pass the result
    #
    def progress_data( opts= {}, &block )

        include_messages = opts[:messages].nil? ? true : opts[:messages]
        include_slaves   = opts[:slaves].nil? ? true : opts[:slaves]
        include_issues   = opts[:issues].nil? ? true : opts[:issues]

        as_hash = opts[:as_hash] ? true : opts[:as_hash]

        data = {
            'stats'  => {},
            'status' => status,
            'busy'   => extended_running?
        }

        data['messages']  = flush_buffer if include_messages

        if include_issues
            data['issues'] = as_hash ? issues_as_hash : issues
        end

        data['instances'] = {} if include_slaves

        stats = []
        stat_hash = {}
        stats( true, true ).each { |k, v| stat_hash[k.to_s] = v }

        if master? && include_slaves
            data['instances'][self_url] = stat_hash.dup
            data['instances'][self_url]['url'] = self_url
            data['instances'][self_url]['status'] = status
        end

        stats << stat_hash

        if @instances.empty? || !include_slaves
            data['stats'] = merge_stats( stats )
            data['instances'] = data['instances'].values if include_slaves
            block.call( data )
            return
        end

        foreach = proc do |instance, iter|
            instance.framework.progress_data( opts ) do |tmp|
                if !tmp.rpc_exception?
                    tmp['url'] = instance.url
                    iter.return( tmp )
                else
                    iter.return( nil )
                end
            end
        end

        after = proc do |slave_data|
            slave_data.compact!
            slave_data.each do |slave|
                data['messages']  |= slave['messages'] if include_messages
                data['issues']    |= slave['issues'] if include_issues

                if include_slaves
                    url = slave['url']
                    data['instances'][url]           = slave['stats']
                    data['instances'][url]['url']    = url
                    data['instances'][url]['status'] = slave['status']
                end

                stats << slave['stats']
            end

            if include_slaves
                sorted_data_instances = {}
                data['instances'].keys.sort.each do |url|
                    sorted_data_instances[url] = data['instances'][url]
                end
                data['instances'] = sorted_data_instances.values
            end

            data['stats'] = merge_stats( stats )

            #sitemap_size do |sitemap_size|
            #    data['sitemap_size'] = sitemap_size
            #    block.call( data )
            #end

            block.call( data )
        end

        map_slaves( foreach, after )
    end
    alias :progress :progress_data

    def sitemap( &block )
        spider.collect_sitemaps( &block )
    end

    #
    # Returns the results of the audit as a hash.
    #
    # @return   [Hash]
    #
    def report
        audit_store.to_h
    end
    alias :audit_store_as_hash :report
    alias :auditstore_as_hash :report

    def report_as( name )
        if !reports.available.include?( name.to_s )
            fail Arachni::Exceptions::ComponentNotFound,
                 "Report '#{name}' could not be found."
        end
        if !reports[name].has_outfile?
            fail TypeError, "Report '#{name}' cannot format the audit results as a String."
        end

        outfile = "/tmp/arachn_report_as.#{name}"
        reports.run_one( name, auditstore, 'outfile' => outfile )

        str = IO.read( outfile )
        File.delete( outfile )
        str
    end

    # @return   [String]    YAML representation of {#auditstore}
    def serialized_auditstore
        audit_store.to_yaml
    end

    # @return   [String]    YAML representation of {#report}
    def serialized_report
        audit_store.to_h.to_yaml
    end

    # @return  [Array<Arachni::Issue>]  all discovered issues albeit without any variations
    def issues
        auditstore.issues.deep_clone.map do |issue|
            issue.variations.clear
            issue
        end
    end

    #
    # @return   [Array<Hash>]   {#issues} as an array of hashes
    #
    # @see #issues
    #
    def issues_as_hash
        issues.map { |i| i.to_h }
    end

    #
    # The following methods need to be accessible over RPC but are *privileged*.
    #
    # They're used for intra-Grid communication between masters and their slaves
    #
    #

    #
    # Restricts the scope of the audit to individual elements.
    #
    # @param    [Array<String>]     elements    list of element IDs (as created
    #                                               by {Arachni::Element::Capabilities::Auditable#scope_audit_id})
    # @param    [String]    token       privileged token, prevents this method
    #                                       from being called by 3rd parties when
    #                                       this instance is a master.
    #                                       If this instance is not a master one
    #                                       the token needn't be provided.
    #
    # @return   [Bool]  true on success, false on invalid token
    #
    def restrict_to_elements( elements, token = nil )
        return false if master? && !valid_token?( token )
        Element::Capabilities::Auditable.restrict_to_elements( elements )
        true
    end

    def update_element_ids_per_page( element_ids_per_page = {}, token = nil,
                                     signal_done_peer_url = false )
        return false if master? && !valid_token?( token )

        #ap 'update_element_ids_per_page'
        #ap Kernel.caller.first
        #ap element_ids_per_page

        element_ids_per_page.each do |url, ids|
            @element_ids_per_page[url] ||= []
            @element_ids_per_page[url] |= ids
        end

        if signal_done_peer_url
            spider.peer_done signal_done_peer_url
        end

        true
    end

    #
    # Updates the page queue with the provided pages.
    #
    # @param    [Array<Arachni::Page>]     pages       list of pages
    # @param    [String]    token       privileged token, prevents this method
    #                                       from being called by 3rd parties when
    #                                       this instance is a master.
    #                                       If this instance is not a master one
    #                                       the token needn't be provided.
    #
    # @return   [Bool]  true on success, false on invalid token
    #
    def update_page_queue( pages, token = nil )
        return false if master? && !valid_token?( token )
        [pages].flatten.each { |page| push_to_page_queue( page )}
        true
    end

    #
    # Registers an array holding {Arachni::Issue} objects with the local instance.
    #
    # Primarily used by slaves to register issues they find on the spot.
    #
    # @param    [Array<Arachni::Issue>]    issues
    # @param    [String]    token       privileged token, prevents this method
    #                                       from being called by 3rd parties when
    #                                       this instance is a master.
    #                                       If this instance is not a master one
    #                                       the token needn't be provided.
    #
    # @return   [Bool]  true on success, false on invalid token or if not in HPG mode
    #
    def register_issues( issues, token = nil )
        return false if master? && !valid_token?( token )
        @modules.class.register_results( issues )
        true
    end

    #
    # Sets the URL and authentication token required to connect to the instance's master.
    #
    # @param    [String]    url     master's URL in 'hostname:port' form
    # @param    [String]    token   master's authentication token
    #
    # @return   [Bool]  true on success, false if the current instance is the master of the HPG
    #                       (in which case this method is not applicable)
    #
    def set_master( url, token )
        return false if master?

        @master_url = url
        @master = connect_to_instance( 'url' => url, 'token' => token )

        #spider.master = @master

        @slave_element_ids_per_page ||= {}

        @elem_ids_filter ||= Arachni::BloomFilter.new

        spider.on_each_page do |page|
            @status = :crawling

            @override_sitemap << page.url

            ids = build_elem_list( page ).reject do |id|
                if @elem_ids_filter.include? id
                    true
                else
                    @elem_ids_filter << id
                    false
                end
            end

            next if ids.empty?

            @slave_element_ids_per_page[page.url] = ids.map { |i| i }
        end

        spider.after_each_run do
            if !@slave_element_ids_per_page.empty?

                #ap 'SLAVE -- AFTER EACH RUN'
                #ap @slave_element_ids_per_page

                @master.framework.
                    update_element_ids_per_page( @slave_element_ids_per_page.dup,
                                               master_priv_token,
                                               spider.done? ? self_url : false ){}

                @slave_element_ids_per_page.clear
            else
                spider.signal_if_done( @master )
            end
        end

        # ...and also send the pages in the queue in case it has been
        # populated by a plugin.
        #spider.on_complete do
        #    while !@page_queue.empty? && page = @page_queue.pop
        #        @master.framework.update_page_queue( page, master_priv_token ){}
        #    end
        #end

        @modules.do_not_store
        @modules.on_register_results { |r| report_issues_to_master( r ) }
        true
    end

    def self_url
        @self_url ||= "#{@opts.rpc_address}:#{@opts.rpc_port}"
    end

    private

    def auditstore_sitemap
        (@override_sitemap | @sitemap).to_a
    end

    def extended_running?
        !!@extended_running
    end

    def valid_token?( token )
        @local_token == token
    end

    #
    # Reports an array of issues back to the master instance.
    #
    # @param    [Array<Arachni::Issue>]     issues
    #
    def report_issues_to_master( issues )
        @master.framework.register_issues( issues, master_priv_token ){}
        true
    end

    def master_priv_token
        @opts.datastore['master_priv_token']
    end

    def gen_token
        Digest::SHA2.hexdigest( 10.times.map{ rand( 9999 ) }.join( '' ) )
    end

end

end
end
end
