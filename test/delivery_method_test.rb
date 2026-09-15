# frozen_string_literal: true

require "test_helper"
require "json"
require "mail"
require "socket"
require "mailersend_rails/delivery_method"

module MailersendRails
  class DeliveryMethodTest < TestCase
    def setup
      super
      MailersendRails.config.api_token = "test-token"
    end

    # A real socket rather than a stubbed client: the point of dropping the SDK
    # was to own the request, so the test asserts what actually goes on the wire.
    def with_api(status: "202 Accepted", body: "{}")
      server = TCPServer.new("127.0.0.1", 0)
      captured = nil

      thread = Thread.new do
        socket = server.accept
        headers = +""
        headers << socket.readpartial(4096) until headers.include?("\r\n\r\n")
        head, _, rest = headers.partition("\r\n\r\n")
        length = head[/^Content-Length:\s*(\d+)/i, 1].to_i
        rest << socket.readpartial(4096) while rest.bytesize < length
        captured = { head: head, body: rest }
        socket.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
        socket.close
      end

      yield "http://127.0.0.1:#{server.addr[1]}/v1/email"
      thread.join(5)
      captured
    ensure
      server&.close
    end

    def deliver(mail, endpoint)
      DeliveryMethod.new(endpoint: endpoint).deliver!(mail)
    end

    def build_mail(subject: "Your card is on its way", html: "<p>On its way.</p>", text: nil, **fields)
      mail = Mail::Message.new
      mail.from = fields.fetch(:from, "post@example.com")
      mail.to = fields.fetch(:to, "ada@example.com")
      mail.cc = fields[:cc] if fields[:cc]
      mail.bcc = fields[:bcc] if fields[:bcc]
      mail.reply_to = fields[:reply_to] if fields[:reply_to]
      mail.subject = subject

      if text
        mail.text_part = part("text/plain; charset=UTF-8", text)
        mail.html_part = part("text/html; charset=UTF-8", html)
      else
        mail.content_type = "text/html; charset=UTF-8"
        mail.body = html
      end

      mail
    end

    def part(content_type, body)
      part = Mail::Part.new
      part.content_type = content_type
      part.body = body
      part
    end

    def test_posts_the_message_as_json_to_the_email_endpoint
      mail = build_mail(from: "The Pen & Post <post@example.com>", to: "Ada <ada@example.com>")

      captured = with_api { |endpoint| deliver(mail, endpoint) }

      assert_match(%r{\APOST /v1/email HTTP/1\.1}, captured[:head])
      assert_match(/^Authorization: Bearer test-token\r?$/i, captured[:head])
      assert_match(%r{^Content-Type: application/json\r?$}i, captured[:head])
      assert_match(%r{^User-Agent: mailersend_rails/#{Regexp.escape(MailersendRails::VERSION)}\r?$}i, captured[:head])

      payload = JSON.parse(captured[:body])
      assert_equal({ "email" => "post@example.com", "name" => "The Pen & Post" }, payload["from"])
      assert_equal([ { "email" => "ada@example.com", "name" => "Ada" } ], payload["to"])
      assert_equal "Your card is on its way", payload["subject"]
      assert_equal "<p>On its way.</p>", payload["html"]
    end

    def test_carries_cc_bcc_reply_to_and_the_text_part
      mail = build_mail(
        cc: "cc@example.com", bcc: "bcc@example.com",
        reply_to: "Replies <replies@example.com>",
        subject: "Both parts", text: "On its way."
      )

      payload = JSON.parse(with_api { |endpoint| deliver(mail, endpoint) }[:body])

      assert_equal [ { "email" => "cc@example.com", "name" => nil } ], payload["cc"]
      assert_equal [ { "email" => "bcc@example.com", "name" => nil } ], payload["bcc"]
      assert_equal({ "email" => "replies@example.com", "name" => "Replies" }, payload["reply_to"])
      assert_equal "On its way.", payload["text"]
      assert_equal "<p>On its way.</p>", payload["html"]
    end

    # The failure this guards is silent and only happens in production: a field is
    # one object whose `to_s` is the whole comma-joined list, so parsing it as an
    # address keeps the first name on the list and drops everyone behind them.
    def test_sends_to_every_recipient_on_a_field
      mail = build_mail(
        to: "Ada <ada@example.com>, grace@example.com, Alan <alan@example.com>",
        cc: "one@example.com, two@example.com"
      )

      payload = JSON.parse(with_api { |endpoint| deliver(mail, endpoint) }[:body])

      assert_equal %w[ada@example.com grace@example.com alan@example.com],
                   payload["to"].map { |entry| entry["email"] }
      assert_equal [ "Ada", nil, "Alan" ], payload["to"].map { |entry| entry["name"] }
      assert_equal %w[one@example.com two@example.com], payload["cc"].map { |entry| entry["email"] }
    end

    # MailerSend rejects an empty list where it accepts an absent key, which is
    # what the SDK's own compaction was for.
    def test_omits_the_fields_there_is_nothing_to_say_for
      mail = build_mail(subject: "Nothing else", html: "<p>Nothing else.</p>")

      payload = JSON.parse(with_api { |endpoint| deliver(mail, endpoint) }[:body])

      assert_equal %w[from to subject html], payload.keys
      %w[cc bcc reply_to text in_reply_to references].each { |key| refute_includes payload, key }
    end

    # Threading is invisible until it is wrong, and then it is invisible in the
    # other direction: the reply arrives as a conversation of its own, which
    # reads as the app having ignored the thread rather than as two fields
    # missing from a JSON body.
    def test_carries_in_reply_to_and_references
      mail = build_mail
      mail.in_reply_to = "<parent@example.com>"
      mail.references = [ "<first@example.com>", "<parent@example.com>" ]

      payload = JSON.parse(with_api { |endpoint| deliver(mail, endpoint) }[:body])

      assert_equal "<parent@example.com>", payload["in_reply_to"]
      assert_equal %w[<first@example.com> <parent@example.com>], payload["references"]
    end

    # The mail gem strips the angle brackets off every id it parses, whatever
    # shape the mailer wrote them in, and MailerSend validates against the RFC
    # 5322 form. So both spellings have to arrive bracketed.
    def test_puts_the_angle_brackets_back_on_message_ids
      mail = build_mail
      mail.in_reply_to = "bare@example.com"

      payload = JSON.parse(with_api { |endpoint| deliver(mail, endpoint) }[:body])

      assert_equal "<bare@example.com>", payload["in_reply_to"]
    end

    def test_a_non_2xx_response_raises_so_the_job_retries
      mail = build_mail(subject: "Rejected", html: "<p>Rejected.</p>")

      error = assert_raises(DeliveryMethod::DeliveryError) do
        with_api(status: "422 Unprocessable Entity", body: '{"message":"nope"}') do |endpoint|
          deliver(mail, endpoint)
        end
      end

      assert_match "422", error.message
      assert_match "nope", error.message
    end

    def test_a_missing_token_raises_before_anything_is_sent
      MailersendRails.reset_configuration!
      mail = build_mail(subject: "No token", html: "<p>No token.</p>")

      assert_raises(Configuration::MissingApiToken) do
        DeliveryMethod.new(endpoint: "http://127.0.0.1:1/v1/email").deliver!(mail)
      end
    end

    # Tracking rewrites every link to a redirector on MailerSend's domain, which for a
    # message carrying a credential hands the token to a third party and breaks the
    # Universal Link that would have opened the sender's own app.
    def test_carries_per_message_tracking_settings
      mail = build_mail
      mail["X-MailerSend-Track-Clicks"] = "false"

      captured = with_api { |endpoint| deliver(mail, endpoint) }

      assert_equal({ "track_clicks" => false }, JSON.parse(captured[:body])["settings"])
    end

    def test_carries_every_tracking_switch_it_is_given
      mail = build_mail
      mail["X-MailerSend-Track-Clicks"] = "false"
      mail["X-MailerSend-Track-Opens"] = "FALSE"
      mail["X-MailerSend-Track-Content"] = "true"

      captured = with_api { |endpoint| deliver(mail, endpoint) }

      assert_equal({ "track_clicks" => false, "track_opens" => false, "track_content" => true },
                   JSON.parse(captured[:body])["settings"])
    end

    # Absent means absent: MailerSend falls back to the domain's own setting, and a message
    # that says nothing should keep whatever the account is configured for.
    def test_omits_settings_when_no_message_asks_for_any
      captured = with_api { |endpoint| deliver(build_mail, endpoint) }

      refute JSON.parse(captured[:body]).key?("settings")
    end

    # Loudly, for the same reason a failed delivery is loud: the caller that asked for
    # tracking off is usually sending a credential, and the failure mode of guessing is a
    # token quietly routed through a redirector.
    def test_refuses_a_tracking_value_it_cannot_read
      mail = build_mail
      mail["X-MailerSend-Track-Clicks"] = "off"

      # No server: the payload is refused before anything is sent.
      error = assert_raises(DeliveryMethod::DeliveryError) do
        deliver(mail, "http://127.0.0.1:1/v1/email")
      end

      assert_match(/X-MailerSend-Track-Clicks/, error.message)
    end
  end
end
