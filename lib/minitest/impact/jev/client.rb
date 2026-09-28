# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Minitest
  module Impact
    module Jev
      # A minimal client for TypeSafe's System One endpoint (docs.typesafe.ai/api): one POST with a
      # state and named questions, answers under the same names. The `jev` gem (0.2.0) was
      # considered first; it always sends "jev-latest" and one fixed URL, and a threshold tuned on
      # one version needs that version pinned (docs.typesafe.ai/models).
      class Client
        DEFAULT_BASE_URL = "https://api.typesafe.ai"
        # Pinned: the thresholds in Questions were set against this version.
        DEFAULT_MODEL = "jev-1.13.0"
        RETRY_STATUSES = [429, 529].freeze
        ATTEMPTS = 3
        TIMEOUT = 15

        Response = Struct.new(:answers, :model, :input_tokens, keyword_init: true)

        class Failure < Error; end

        def self.from_env(env = ENV)
          key = env["TYPESAFE_API_KEY"].to_s
          return nil if key.empty?

          new(api_key: key, base_url: env.fetch("TYPESAFE_BASE_URL", DEFAULT_BASE_URL),
              model: env.fetch("MINITEST_IMPACT_JEV_MODEL", DEFAULT_MODEL))
        end

        attr_reader :model

        def initialize(api_key:, base_url: DEFAULT_BASE_URL, model: DEFAULT_MODEL, sleeper: ->(seconds) { sleep(seconds) })
          @api_key = api_key
          @uri = URI.join(base_url.end_with?("/") ? base_url : "#{base_url}/", "v1/systemone")
          @model = model
          @sleeper = sleeper
        end

        def ask(state:, questions:)
          attempt = 0
          begin
            attempt += 1
            response = post(JSON.generate(model: model, state: state, questions: questions))
            if RETRY_STATUSES.include?(response.code.to_i) && attempt < ATTEMPTS
              @sleeper.call(retry_after(response, attempt))
              raise RetryableStatus
            end
            parse(response)
          rescue RetryableStatus
            retry
          rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => error
            raise Failure, "Jev unreachable: #{error.class}"
          end
        end

        private

        class RetryableStatus < StandardError; end

        def post(body)
          request = Net::HTTP::Post.new(@uri, "Content-Type" => "application/json", "Authorization" => "Bearer #{@api_key}")
          request.body = body
          Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
            http.request(request)
          end
        end

        def retry_after(response, attempt)
          header = response["retry-after"].to_s
          header.match?(/\A\d+(\.\d+)?\z/) ? header.to_f : 0.5 * (2**attempt)
        end

        def parse(response)
          raise Failure, "Jev answered #{response.code}: #{response.body.to_s[0, 200]}" unless response.is_a?(Net::HTTPSuccess)

          body = JSON.parse(response.body)
          Response.new(answers: body.fetch("answers"), model: body.fetch("model"), input_tokens: body.dig("usage", "input_tokens").to_i)
        rescue JSON::ParserError, KeyError => error
          raise Failure, "Jev answered something unreadable: #{error.class}"
        end
      end
    end
  end
end
