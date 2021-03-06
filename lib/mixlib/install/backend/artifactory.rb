#
# Author:: Patrick Wright (<patrick@chef.io>)
# Copyright:: Copyright (c) 2015 Chef, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "net/http"
require "json"
require "mixlib/install/artifact_info"
require "artifactory"

module Mixlib
  class Install
    class Backend
      class Artifactory
        class ConnectionError < StandardError; end
        class AuthenticationError < StandardError; end
        class NoArtifactsError < StandardError; end

        ENDPOINT = "http://artifactory.chef.co".freeze

        attr_accessor :options

        def initialize(options)
          @options = options
        end

        # Create filtered list of artifacts
        #
        # @return [Array<ArtifactInfo>] list of artifacts for the configured
        # channel, product name, and product version.
        # @return [ArtifactInfo] arifact info for the configured
        # channel, product name, product version and platform info
        #
        def info
          artifacts = if options.latest_version?
            artifactory_latest
          else
            artifactory_artifacts(options.product_version)
          end

          if options.platform
            artifacts.select! do |a|
              a.platform == options.platform &&
                a.platform_version == options.platform_version &&
                a.architecture == options.architecture
            end
          end

          artifacts.length == 1 ? artifacts.first : artifacts
        end

        #
        # Get artifacts for the latest version, channel and product_name
        #
        # @return [Array<ArtifactInfo>] Array of info about found artifacts
        def artifactory_latest
          # Get the list of builds from the REST api.
          # We do this because a user in the readers group does not have
          # permissions to run aql against builds.
          builds = client.get("/api/build/#{options.product_name}")

          if builds.nil?
            raise NoArtifactsError, <<-MSG
Can not find any builds for #{options.product_name} in #{::Artifactory.endpoint}.
            MSG
          end

          # Output we get is something like:
          # {
          #   "buildsNumbers": [
          #     {"uri"=>"/12.5.1+20151213083009", "started"=>"2015-12-13T08:40:19.238+0000"},
          #     {"uri"=>"/12.6.0+20160111212038", "started"=>"2016-01-12T00:25:35.762+0000"},
          #     ...
          #   ]
          # }
          # First we sort based on started
          builds["buildsNumbers"].sort_by! { |b| b["started"] }.reverse!

          # Now check if the build is in the requested channel or not
          # Note that if you do this for any channel other than :unstable
          # it will run a high number of queries but it is fine because we
          # are using artifactory only for :unstable channel
          builds["buildsNumbers"].each do |build|
            version = build["uri"].gsub("/", "")
            artifacts = artifactory_artifacts(version)

            return artifacts unless artifacts.empty?
          end

          # we could not find any matching artifacts
          []
        end

        #
        # Get artifacts for a given version, channel and product_name
        #
        # @return [Array<ArtifactInfo>] Array of info about found artifacts
        def artifactory_artifacts(version)
          results = artifactory_query(<<-QUERY)
items.find(
  {"repo": "omnibus-#{options.channel}-local"},
  {"@omnibus.project": "#{options.product_name}"},
  {"@omnibus.version": "#{version}"}
).include("repo", "path", "name", "property")
          QUERY

          # Merge artifactory properties and downloadUri to a flat Hash
          results.collect! do |result|
            { "downloadUri" => generate_download_uri(result) }.merge(
              map_properties(result["properties"])
            )
          end

          # Convert results to build records
          results.map { |a| create_artifact(a) }
        end

        #
        # Run an artifactory query for the given query.
        #
        # @return [Array<Hash>] Array of results returned from artifactory
        def artifactory_query(query)
          results = artifactory_request do
            client.post("/api/search/aql", query, "Content-Type" => "text/plain")
          end

          results["results"]
        end

        def create_artifact(artifact_map)
          ArtifactInfo.new(
            md5:              artifact_map["omnibus.md5"],
            sha256:           artifact_map["omnibus.sha256"],
            version:          artifact_map["omnibus.version"],
            platform:         artifact_map["omnibus.platform"],
            platform_version: artifact_map["omnibus.platform_version"],
            architecture:     artifact_map["omnibus.architecture"],
            url:              artifact_map["downloadUri"]
          )
        end

        private

        # Converts Array<Hash> where the Hash is a key pair and
        # value pair to a simplifed key/pair Hash
        #
        def map_properties(properties)
          return {} if properties.nil?
          properties.each_with_object({}) do |prop, h|
            h[prop["key"]] = prop["value"]
          end
        end

        # Construct the downloadUri from raw artifactory data
        #
        def generate_download_uri(result)
          uri = []
          uri << endpoint.sub(/\/$/, "")
          uri << result["repo"]
          uri << result["path"]
          uri << result["name"]
          uri.join("/")
        end

        def client
          @client ||= ::Artifactory::Client.new(
            endpoint: endpoint,
            username: ENV["ARTIFACTORY_USERNAME"],
            password: ENV["ARTIFACTORY_PASSWORD"]
          )
        end

        def endpoint
          @endpoint ||= ENV.fetch("ARTIFACTORY_ENDPOINT", ENDPOINT)
        end

        def artifactory_request
          begin
            results = yield
          rescue Errno::ETIMEDOUT, ::Artifactory::Error::ConnectionError
            raise ConnectionError, <<-EOS
Artifactory endpoint '#{::Artifactory.endpoint}' is unreachable. Check that
the endpoint is correct and there is an open connection to Chef's private network.
            EOS
          rescue ::Artifactory::Error::HTTPError => e
            if e.code == 401 && e.message =~ /Bad credentials/
              raise AuthenticationError, <<-EOS
Artifactory server denied credentials. Verify ARTIFACTORY_USERNAME and
ARTIFACTORY_PASSWORD environment variables are configured properly.
              EOS
            else
              raise e
            end
          end

          results
        end
      end
    end
  end
end
