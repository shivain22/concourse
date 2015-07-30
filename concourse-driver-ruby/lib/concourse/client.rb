# Copyright (c) 2015 Cinchapi, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'concourse/thrift/concourse_service'

module Concourse

    # This is an alias for the Concourse::Client constructor
    # @return [Concourse::Client] the handle
    def self.connect(host: "localhost", port: 1717, username: "admin", password: "admin", environment: "", **kwargs)
        return Concourse::Client.new(host: host, port: port, username: username, password: password, environment: environment, **kwargs)
    end

    # Concourse is a self-tuning database that makes it easier to quickly build
    # reliable and scalable systems. Concourse dynamically adapts to any
    # application and offers features like automatic indexing, version control,
    # and distributed ACID transactions within a smart platform that manages
    # itself, reduces costs and allows developers to focus on what really
    # matters.
    #
    # == Data Model
    # The Concourse data model is lightweight and flexible. Unlike other
    # databases, Concourse is completely schemaless and does not hold data in
    # tables or collections. Concourse is simply a distributed document-graph
    # where data is stored in records (similar to documents or rows in other
    # databases). Each record has multiple keys. And each key has one or more
    # distinct values. Like any graph, you can link records to one another. And
    # the structure of one record does not affect the structure of another.
    #
    # *Record*: A logical grouping of data about a single person, place or thing
    # (i.e. an object). Each record is identified by a unique primary key.
    # *Key*: A attribute that maps to one or more distinct values.
    # *Value*:  A dynamically typed quantity.
    #
    # == Data Types
    # Concourse natively stores the following primitives: boolean, double,
    # integer, string (UTF-8) and Tag (a string that is not full text
    # searchable). Any other data type will be stored as its to_s
    # representation.
    #
    # == Links
    # Concourse allows linking a key in one record to another record using the
    # link() function. Links are retrievable and queryable just like any other
    # value.
    #
    # == Transactions
    # By default, Concourse conducts every operation in autocommit mode where
    # every change is immediately written. You can also stage a group of
    # operations in an ACID transaction. Transactions are managed using the
    # #stage, #commit and #abort commands.
    #
    # == Version Control
    # Concourse automatically tracks every changes to data and the API exposes
    # several methods to tap into this feature.
    # 1) You can get() and select() previous version of data by specifying a
    # timestamp using natural language or a unix timestamp integer in
    # microseconds. 2) You can browse() and find() records that matched a
    # criteria in the past by specifying a timestamp using natural language or a
    # unix timestamp integer in microseconds. 3) You can audit() and diff()
    # changes over time, revert() to previous states and chronologize() how data
    # has evolved over a range of time.
    #
    # @author Jeff Nelson
    class Client

        # Initialize a new client connection
        # @param host [String] the server host
        # @param port [Integer] the listener port
        # @param username [String] the username with which to connect
        # @param password [String] the password for the username
        # @param environment [String] the environment to use, by default the default_environment` in the server's concourse.prefs file is used
        # @option kwargs [String] :prefs  You may specify the path to a preferences file using the 'prefs' keyword argument. If a prefs file is supplied, the values contained therewithin for any of the arguments above become the default if those arguments are not explicitly given values.
        #
        # @return [Client] the handle
        def initialize(host = "localhost", port = 1717, username = "admin", password = "admin", environment = "", **kwargs)
            host = kwargs.fetch(:host, host)
            port = kwargs.fetch(:port, port)
            username = kwargs.fetch(:username, username)
            password = kwargs.fetch(:password, password)
            environment = kwargs.fetch(:environment, environment)
            username = username or ::Utils::Args::find_in_kwargs_by_alias('username', kwargs)
            password = password or Utils::Args::find_in_kwargs_by_alias('password', kwargs)
            prefs = Utils::Args::find_in_kwargs_by_alias('prefs', kwargs)
            if !prefs.nil?
                prefs = File.expand_path(prefs)
                data = ::JavaProperties.load(prefs)
            else
                data = {}
            end
            @host = data.fetch(:host, host)
            @port = data.fetch(:port, port)
            @username = data.fetch(:username, username)
            @password = data.fetch(:password, password)
            @environment = data.fetch(:environment, environment)
            begin
                @transport = ::Thrift::BufferedTransport.new(::Thrift::Socket.new(@host, @port))
                @protocol = ::Thrift::BinaryProtocol.new(@transport)
                @client = Thrift::ConcourseService::Client.new(@protocol)
                @transport.open()
            rescue ::Thrift::Exception
                raise "Could not connect to the Concourse Server at #{@host}:#{@port}"
            end
            @transaction = nil
            authenticate()
        end

        # Abort the current transaction and discard any changes that were
        # staged. After returning, the driver will return to autocommit mode and
        # all subsequent changes will be committed imediately.
        # @return [Void]
        def abort
            if !@transaction.nil?
                token = @transaction
                @transaction = nil
                @client.abort @creds, token, @environment
            end
        end

        # Add a value to a key in one or more records
        # @option kwargs [String] :key The field name (*required*)
        # @option kwargs [Object] :value The value to add (*required*)
        # @option kwargs [Integer] :record The record where the data is added (_optional_)
        # @option kwargs [Array] :records The records where the data is added (_optional_)
        # @return [Boolean] if _record_ is supplied, a boolean that indicates whether the value was added
        # @return [Hash] if _records_ is supplied, a mapping from each record id to a boolean indicating whether the value was added in that record
        # @return [Integer] if neither _record_ or _records_ is supplied, the id of a new record where the data was added
        def add(*args, **kwargs)
            key, value, records = args
            key = kwargs.fetch(:key, key)
            value = kwargs.fetch(:value, value)
            records ||= kwargs.fetch(:record, nil)
            records ||= kwargs.fetch(:records, nil)
            value = Utils::Convert::ruby_to_thrift value unless value.nil?
            if records.nil? and key and value
                return @client.addKeyValue key, value, @creds, @transaction, @environment
            elsif records.is_a? Array and key and value
                return @client.addKeyValueRecords key, value, records, @creds, @transaction, @environment
            elsif records.is_a? Integer and key and value
                return @client.addKeyValueRecord key, value, records, @creds, @transaction, @environment
            else
                Utils::Args::require 'key and value'
            end
        end

        # Describe changes made to a record or a field over time.
        # @option kwargs [String] :key The field name (_optional_)
        # @option kwargs [Integer] :record The record id (*required*)
        # @option kwargs [Integer, String] :start The beginning of the time range (_default_: the oldest timestamp)
        # @option kwargs [Integer, String] :end The end of the time range (_default_: the current timestamp)
        # @return [Hash] a mapping from timestamp to a description of the change
        def audit(*args, **kwargs)
            key, record, start, tend = args
            key ||= kwargs[:key]
            record ||= kwargs[:record]
            start ||= kwargs[:start]
            start ||= Utils::Args::find_in_kwargs_by_alias 'timestamp', kwargs
            tend ||= kwargs[:end]
            startstr = start.is_a? String
            endstr = tend.is_a? String

            # If the first arg is an Integer, then assume that we are auditing
            # an entire record.
            if key.is_a? Integer
                record = key
                key = nil
            end

            if key and record and start and !startstr and tend and !endstr
                data = @client.auditKeyRecordStartEnd key, record, start, tend, @creds, @transaction, @environment
            elsif key and record and start and startstr and tend and endstr
                data = @client.auditKeyRecordStartstrEndstr key, record, start, tend, @creds, @transaction, @environment
            elsif key and record and start and !startstr
                data = @client.auditKeyRecordStart key, record, start, @creds, @transaction, @environment
            elsif key and record and start and startstr
                data = @client.auditKeyRecordStartstr key, record, start, @creds, @transaction, @environment
            elsif key and record
                data = @client.auditKeyRecord key, record, @creds, @transaction, @environment
            elsif record and start and !startstr and tend and !endstr
                data = @client.auditRecordStartEnd record, start, tend, @creds, @transaction, @environment
            elsif record and start and startstr and tend and endstr
                data = @client.auditRecordStartstrEndstr record, start, tend, @creds, @transaction, @environment
            elsif record and start and !startstr
                data = @client.auditRecordStart record, start, @creds, @transaction, @environment
            elsif record and start and startstr
                data = @client.auditRecordStartstr record, start, @creds, @transaction, @environment
            elsif record
                data = @client.auditRecord record, @creds, @transaction, @environment
            else
                Utils::Args::require 'record'
            end
            return data
        end

        # Get the most recently added value in one or more fields from one or
        # more records.
        # @option kwargs [String] :key The name of the field to get the data from (*required* along with _criteria_ if _record_ is not specified)
        # @option kwargs [Array] :keys The name of the fields to get the data from (_optional_)
        # @option kwargs [String] :criteria The criteria to use when determining which records to get the data from (*required* along with _key_ if _record_ is not specified)
        # @option kwargs [Integer] :record The record to get the data from (*required* if key and criteria are not specified)
        # @option kwargs [Array] :records A list of records to get the data from (_optional_)
        # @option kwargs [Integer, String] :timestamp The timestamp to use when getting the data (_optional_)
        # @return [Object] if _key_ and _record_ are supplied, the most recently added value in the field
        # @return [Hash] if _key_ and _records_ or _key_ and _criteria_ are supplied, a mapping from each record to the most recently added value in the field named _key_
        # @return [Hash] if _keys_ and _records_ or _keys_ and _criteria_ are supplied, a mapping from each record to a hash mapping each key to the most recently added value in the field
        # @return [Hash] if _keys_ and _record_ are supplied, a mapping from each key to the most recently added value in the field
        # @return [Hash] if _record_ is supplied, a mapping from each key in the record to the most recently added value in the field
        def get(*args, **kwargs)
            keys, criteria, records, timestamp = args
            criteria ||= Utils::Args::find_in_kwargs_by_alias('criteria', kwargs)
            keys ||= kwargs.fetch(:key, nil)
            records = records ||= kwargs.fetch(:record, nil)
            timestamp ||= Utils::Args::find_in_kwargs_by_alias('timestamp', kwargs)
            timestr = timestamp.is_a? String

            # Try to figure out intent if args were used instead of kwargs
            if criteria.is_a? Integer
                records = criteria
                criteria = nil
            end

            if records.is_a? Array and keys.nil? and timestamp.nil?
                data = @client.getRecords records, @creds, @transaction, @environment
            elsif records.is_a? Array and !timestamp.nil? and !timestr and keys.nil?
                data = @client.getRecordsTime records, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Array and !timestamp.nil? and timestr and keys.nil?
                data = @client.getRecordsTimestr records, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Array and keys.is_a? Array and timestamp.nil?
                data = @client.getKeysRecords keys, records, @creds, @transaction, @environment
            elsif records.is_a? Array and keys.is_a? Array and !timestamp.nil? and !timestr
                data = @client.getKeysRecordsTime keys, records, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Array and keys.is_a? Array and !timestamp.nil? and timestr
                data = @client.getKeysRecordsTimestr keys, records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? Array and !criteria.nil? and timestamp.nil?
                data = @client.getKeysCcl keys, criteria, @creds, @transaction, @environment
            elsif keys.is_a? Array and !criteria.nil? and !timestamp.nil? and !timestr
                data = @client.getKeysCclTime keys, criteria, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? Array and !criteria.nil? and !timestamp.nil? and timestr
                data = @client.getKeysCclTimestr keys, criteria, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? Array and records.is_a? Integer and timestamp.nil?
                data = @client.getKeysRecord keys, records, @creds, @transaction, @environment
            elsif keys.is_a? Array and records.is_a? Integer and !timestamp.nil? and !timestr
                data = @client.getKeysRecordTime keys, records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? Array and records.is_a? Integer and timestamp.nil? and timestr
                data = @client.getKeysRecordTimestr keys, records, timestamp, @creds, @transaction, @environment
            elsif !criteria.nil? and keys.nil? and timestamp.nil?
                data = @client.getCcl criteria, @creds, @transaction, @environment
            elsif !criteria.nil? and !timestamp.nil? and !timestr and keys.nil?
                data = @client.getCclTime criteria, timestamp, @creds, @transaction, @environment
            elsif !criteria.nil? and !timestamp.nil? and timestr and keys.nil?
                data = @client.getCclTimestr criteria, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Integer and keys.nil? and timestamp.nil?
                data = @client.getRecord records, @creds, @transaction, @environment
            elsif records.is_a? Integer and !timestamp.nil? and !timestr and keys.nil?
                data = @client.getRecordTime records, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Integer and !timestamp.nil? and timestr and keys.nil?
                data = @client.getRecordTimestr records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? String and !criteria.nil? and timestamp.nil?
                data = @client.getKeyCcl keys, criteria, @creds, @transaction, @environment
            elsif keys.is_a? String and !criteria.nil? and !timestamp.nil and !timestr
                data = @client.getKeyCclTime keys, criteria, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? String and !criteria.nil? and !timestamp.nil? and timestr
                data = @client.getKeyCclTimestr keys, criteria, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Array and timestamp.nil?
                data = @client.getKeyRecords keys, records, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Integer and timestamp.nil?
                data = @client.getKeyRecord keys, records, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Array and !timestamp.nil? and !timestr
                data = @client.getKeyRecordsTime keys, records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Array and !timestamp.nil? and timestr
                data = @client.getKeyRecordsTimestr keys, records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Integer and !timestamp.nil? and !timestr
                data = @client.getKeyRecordTime keys, records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Integer and !timestamp.nil and timestr
                data = @client.getKeyRecordTimestr keys, records, timestamp, @creds, @transaction, @environment
            else
                Utils::Args::require('record or (key and criteria)')
            end
            return Utils::Convert::rubyify data
        end

        # Return the environment to which the client is connected.
        # @return [String] the server environment associated with this connection
        def get_server_environment
            return @client.getServerEnvironment @creds, @transaction, @environment
        end

        # Return the version of Concourse Server to which the client is
        # connected. Generally speaking, a client cannot talk to a newer version
        # of Concourse Server.
        # @return [String] the server version
        def get_server_version
            return @client.getServerVersion
        end

        # An internal method that allows unit tests to "logout" from the server
        # without closing the transport. This should only be used in unit tests
        # that are connected to Mockcourse.
        # @!visibility private
        def logout()
            @client.logout(@creds, @environment)
        end

        def select(*args, **kwargs)
            keys, criteria, records, timestamp = args
            criteria ||= Utils::Args::find_in_kwargs_by_alias('criteria', kwargs)
            keys ||= kwargs.fetch(:key, nil)
            records = records ||= kwargs.fetch(:record, nil)
            timestamp ||= Utils::Args::find_in_kwargs_by_alias('timestamp', kwargs)
            timestr = timestamp.is_a? String

            if records.is_a? Array and !keys and !timestamp
                data = @client.selectRecords records, @creds, @transaction, @environment
            elsif records.is_a? Array and !keys and timestamp and !timestr
                data = @client.selectRecordsTime records, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Array and !keys and timestamp and timestr
                data = @client.selectRecordsTimestr records, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Array and keys.is_a? Array and !timestamp
                data = @client.selectKeysRecords keys, records, @creds, @transaction, @environment
            elsif records.is_a? Array and keys.is_a? Array and timestamp and !timestr
                data = @client.selectKeysRecordsTime keys, records, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Array and keys.is_a? Array and timestamp and timestr
                data = @client.selectKeysRecordsTimestr keys, records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? Array and criteria and !timestamp
                data = @client.selectKeysCcl keys, criteria, @creds, @transaction, @environment
            elsif keys.is_a? Array and criteria and timestamp and !timestr
                data = @client.selectKeysCclTime keys, criteria, @creds, @transaction, @environment
            elsif keys.is_a? Array and criteria and timestamp and timestr
                data = @client.selectKeysCclTimestr keys, criteria, @creds, @transaction, @environment
            elsif keys.is_a? Array and records.is_a? Integer and !timestamp
                data = @client.selectKeysRecord keys, records, @creds, @transaction, @environment
            elsif keys.is_a? Array and records.is_a? Integer and timestamp and !timestr
                data = @client.selectKeysRecordTime keys, records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? Array and records.is_a? Integer and timestamp and timestr
                data = @client.selectKeysRecordTimestr keys, records, timestamp, @creds, @transaction, @environment
            elsif criteria and !keys and !timestamp
                data = @client.selectCcl criteria, @creds, @transaction, @environment
            elsif criteria and !keys and timestamp and !timestr
                data = @client.selectCclTime criteria, timestamp, @creds, @transaction, @environment
            elsif criteria and !keys and timestamp and timestr
                data = @client.selectCclTimestr criteria, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Array and !keys and !timestamp
                data = @client.selectRecords records, @creds, @transaction, @environment
            elsif records.is_a? Array and !keys and timestamp and !timestr
                data = @client.selectRecordsTime records, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Array and !keys and timestamp and timestr
                data = @client.selectRecordsTimestr records, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Integer and !keys and !timestamp
                data = @client.selectRecord records, @creds, @transaction, @environment
            elsif records.is_a? Integer and !keys and timestamp and !timestr
                data = @client.selectRecordTime records, timestamp, @creds, @transaction, @environment
            elsif records.is_a? Integer and !keys and timestamp and timestr
                data = @client.selectRecordTimestr records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? String and criteria and !timestamp
                data = @client.selectKeyCcl keys, criteria, @creds, @transaction, @environment
            elsif keys.is_a? String and criteria and timestamp and !timestr
                data = @client.selectKeyCclTime keys, criteria, @creds, @transaction, @environment
            elsif keys.is_a? String and criteria and timestamp and timestr
                data = @client.selectKeyCclTimestr keys, criteria, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Array and !timestamp
                data = @client.selectKeyRecords keys, records, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Array and timestamp and !timestr
                data = @client.selectKeyRecordsTime keys, records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Array and timestamp and timestr
                data = @client.selectKeyRecordsTimestr keys, records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Integer and !timestamp
                data = @client.selectKeyRecord keys, records, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Integer and timestamp and !timestr
                data = @client.selectKeyRecordTime keys, records, timestamp, @creds, @transaction, @environment
            elsif keys.is_a? String and records.is_a? Integer and timestamp and timestr
                data = @client.selectKeyRecordTimestr keys, records, timestamp, @creds, @transaction, @environment
            else
                Utils::Args::require 'criteria or record'
            end
            return Utils::Convert::rubyify data
        end

        # Atomically remove all existing values from a field and add a new one.
        # @option kwargs [String] :key The field name
        # @option kwargs [Object] :value The value to add
        # @option kwargs [Integer] :record The record where the data is set (_optional_)
        # @option kwargs [Array] :records The records where the data is set (_optional_)
        # @return [Integer] if neither _record_ or _records_ are supplied, the id of a new record where the data was added
        # @return [Void] if _record_ or _records_ is supplied
        def set(*args, **kwargs)
            key, value, records = args
            records ||= kwargs[:record]
            value = Utils::Convert.ruby_to_thrift value
            if !records
                return @client.setKeyValue key, value, @creds, @transaction, @environment
            elsif records.is_a? Array
                return @client.setKeyValueRecords key, value, records, @creds, @transaction, @environment
            elsif records.is_a? Integer
                return @client.setKeyValueRecord key, value, records, @creds, @transaction, @environment
            else
                Utils::Args::require 'record or records'
            end
        end

        # Start a transaction.
        #
        # This method will turn on _staging_ mode so that all subsequent changes
        # are collected in an isolated buffer before possibly being committed.
        # Staged operations are guaranteed to be reliable, all or nothing, units
        # of work that allow correct recovery from failures and provide
        # isolation between clients so the database is always consistent.
        #
        # After this method returns, all subsequent operations will be done in
        # _staging_ mode until either #commit or #abort is called.
        #
        # All operations that occur within a transaction should be wrapped in a
        # begin-rescue block so that transaction exceptions can be caught and
        # the application can decided to abort or retry the transaction:
        #
        #   concourse.stage
        #   begin
        #       concourse.get key:"name", record:1
        #       concourse.add key:"name", value:"Jeff Nelson", record:1
        #       concourse.commit
        #   rescue Concourse::TransactionException
        #       concourse.abort
        #   end
        #
        # @return [Void]
        def stage
            @transaction = @client.stage @creds, @environment
        end

        # Return a unix timestamp in microseconds.
        # @param [String] phrase A natural language description of the timestamp to return (i.e. 3 weeks ago, last month, etc)
        # @return [Integer] the timestamp
        def time(phrase = nil)
            if phrase
                return @client.timePhrase phrase, @creds, @transaction, @environment
            else
                return @client.time @creds, @transaction, @environment
            end
        end

        # Internal method to login with @username and @password and locally
        # store the AccessToken for use with subsequent operations.
        def authenticate()
            begin
                @creds = @client.login(@username, @password, @environment)
            rescue Thrift::Exception => ex
                raise ex
            end
        end

        private :authenticate

    end

    # The base class for all exceptions that happen during (staged) operations
    # in a transaction.
    class TransctionException < RuntimeError

        def initialize
            super "Another client has made changes to data used within the current transaction, so it cannot continue. Please abort the transaction and try again."
        end
    end

end
