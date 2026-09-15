# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "version"

module MailersendRails
  # An Action Mailer delivery method for MailerSend.
  #
  # Failures raise rather than returning quietly, so the enqueuing job retries and
  # the error is visible. Swallowing them means a magic link that silently goes
  # nowhere, which looks to the person waiting for it exactly like a broken app.
  #
  # The API is posted to directly rather than through mailersend-ruby. Sending is
  # a single POST of a JSON body this class already assembles itself, and the SDK
  # asks a lot in return: http, which it pins a major version behind and so holds
  # back every application that carries it, plus an FFI parser that has to be
  # compiled into every image.
  class DeliveryMethod
    class DeliveryError < StandardError; end

    DEFAULT_ENDPOINT = "https://api.mailersend.com/v1/email"

    # The SDK's timeouts, kept because they are sensible: long enough for a slow
    # accept, short enough that a wedged connection fails into the retry rather
    # than occupying a worker.
    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 30

    # MailerSend's per-message tracking switches, and the header each is set from.
    #
    # Tracking rewrites every link in the message to a redirector on MailerSend's
    # domain. For marketing mail that is the point. For a message carrying a
    # credential it is two problems: the token is handed to a third party and
    # logged in their click reporting, and the rewritten URL is no longer yours --
    # so an iOS Universal Link stops matching your apple-app-site-association and
    # opens a browser instead of your app, which for a single-use sign-in link
    # means it is spent somewhere the app cannot see.
    #
    # Absent means absent: MailerSend falls back to the domain's own setting, so a
    # message that says nothing keeps whatever the account is configured for.
    TRACKING = {
      "track_clicks" => "X-MailerSend-Track-Clicks",
      "track_opens" => "X-MailerSend-Track-Opens",
      "track_content" => "X-MailerSend-Track-Content"
    }.freeze

    attr_reader :settings

    def initialize(settings = {})
      @settings = settings || {}
    end

    def deliver!(mail)
      response = post(payload_for(mail))

      return response if success?(response)

      raise DeliveryError, "MailerSend returned #{response.code}: #{response.body}"
    end

    private
      # MailerSend treats an absent field as "not set" but rejects several of them
      # sent empty, so anything we have nothing for is dropped rather than blanked.
      def payload_for(mail)
        {
          "from" => address_in(mail[:from]),
          "to" => addresses_in(mail[:to]),
          "cc" => addresses_in(mail[:cc]),
          "bcc" => addresses_in(mail[:bcc]),
          "reply_to" => Array(mail.reply_to).empty? ? {} : address_in(mail[:reply_to]),
          "subject" => mail.subject,
          "text" => mail.text_part&.body&.decoded,
          "html" => html_for(mail),
          "in_reply_to" => message_ids_in(mail[:in_reply_to]).first,
          "references" => message_ids_in(mail[:references]),
          "settings" => tracking_in(mail)
        }.reject { |_, value| omit?(value) }
      end

      # The tracking switches this message sets, if any. See TRACKING.
      #
      # A value that is neither "true" nor "false" raises rather than being
      # dropped, for the same reason a failed delivery raises: the caller that
      # asked for tracking off is usually sending a credential, and the failure
      # mode of guessing is a token quietly routed through a redirector. A typo
      # here is a mistake in the sender's own code and shows up the first time
      # that mailer is exercised.
      def tracking_in(mail)
        TRACKING.each_with_object({}) do |(field, header), settings|
          raw = mail[header]&.to_s&.strip
          next if raw.nil? || raw.empty?

          case raw.downcase
          when "true" then settings[field] = true
          when "false" then settings[field] = false
          else raise DeliveryError, "#{header} must be \"true\" or \"false\", got #{raw.inspect}"
          end
        end
      end

      # In-Reply-To and References, in the form MailerSend asks for them.
      #
      # Threading is what puts a reply under the message it answers rather than
      # in a conversation of its own, and these two headers are the whole of it.
      # They need carrying by hand because the API takes fields rather than a
      # MIME message: every header Action Mailer set that isn't named in
      # #payload_for is dropped here, and a mailer that sets In-Reply-To and
      # then watches its reply arrive as a new thread has nowhere to look for
      # where it went. Both fields are paid-plan only at MailerSend, which
      # answers a request carrying them on a free account with a 422 -- loudly,
      # like every other delivery failure.
      #
      # The `mail` gem hands ids back with the angle brackets stripped and
      # MailerSend validates against the RFC 5322 form, so they go back on. A
      # field too malformed to parse falls back to splitting on whitespace,
      # which is the shape of both headers.
      def message_ids_in(field)
        return [] if field.nil?

        ids = field.respond_to?(:message_ids) ? field.message_ids : field.to_s.split
        Array(ids).filter_map { |id| bracketed(id) }
      end

      def bracketed(id)
        id = id.to_s.strip.delete_prefix("<").delete_suffix(">").strip

        "<#{id}>" unless id.empty?
      end

      def html_for(mail)
        mail.html_part&.body&.decoded || mail.body.decoded
      end

      def address_in(field)
        as_recipient(Mail::Address.new(field.to_s))
      end

      # `mail[:to]` is one field whose `to_s` is the whole comma-joined list, and
      # `Mail::Address.new` on that parses the first address and drops the rest --
      # which is how a three-person ops alias arrives as one person, silently and
      # only in production. The field already holds the addresses parsed.
      def addresses_in(field)
        Array(field&.addrs).map { |address| as_recipient(address) }
      end

      def as_recipient(address)
        { "email" => address.address, "name" => address.display_name }
      end

      def omit?(value)
        value == [] || value == {} || value.to_s.strip.empty?
      end

      def success?(response)
        response.code.to_s.start_with?("2")
      end

      # Overridable so a test, or a staging environment, can point somewhere other
      # than the live API.
      def endpoint
        @endpoint ||= URI(settings[:endpoint] || DEFAULT_ENDPOINT)
      end

      def post(payload)
        request = Net::HTTP::Post.new(endpoint)
        request["Authorization"] = "Bearer #{MailersendRails.config.api_token!}"
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request["User-Agent"] = "mailersend_rails/#{MailersendRails::VERSION}"
        request.body = JSON.generate(payload)

        Net::HTTP.start(
          endpoint.hostname, endpoint.port,
          use_ssl: endpoint.scheme == "https",
          open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
        ) { |http| http.request(request) }
      end
  end
end
