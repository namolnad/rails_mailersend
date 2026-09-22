# frozen_string_literal: true

require "test_helper"
require "rails"
require "action_controller"
require "action_controller/log_subscriber"
require "mailersend_rails/inbound/controller"

# Everything MailerSend posts is somebody's mail: the whole RFC822 message in
# `data.raw`, and the same words again in `data.text` and `data.html`. None of
# it may reach the log -- a refused post least of all, since anybody can send
# one.
#
# The success path needs Action Mailbox and a database, so it is exercised by
# the apps that mount this; what is checked here is the part that holds whether
# or not a message is accepted.
class InboundControllerTest < MailersendRails::TestCase
  SECRET = "route-secret"
  PRIVATE = "the part of this message nobody else should read"

  def setup
    super
    @log = StringIO.new
    @loggers = [ Rails.logger, ActionController::Base.logger ]
    # Both: an app writes its request lines through one and this gem's own
    # lines through the other.
    Rails.logger = ActionController::Base.logger = ActiveSupport::Logger.new(@log)
  end

  def teardown
    Rails.logger, ActionController::Base.logger = @loggers
    super
  end

  def test_a_forged_post_is_refused_without_its_mail_reaching_the_log
    MailersendRails.configure { |config| config.inbound_secret = SECRET }

    status = post(inbound_message, signature: "forged")

    assert_equal 401, status
    assert_includes @log.string, "bad signature"
    refute_includes @log.string, PRIVATE
  end

  def test_a_post_refused_for_want_of_a_secret_leaves_the_mail_out_too
    status = post(inbound_message, signature: "anything")

    assert_equal 503, status
    refute_includes @log.string, PRIVATE
  end

  def test_the_validation_ping_is_still_answered_first
    status = post(JSON.generate("type" => "webhook.test"), signature: nil)

    assert_equal 200, status
    assert_includes @log.string, "answered a validation ping"
  end

  private
    def inbound_message
      JSON.generate(
        "type" => "inbound.message",
        "data" => {
          "raw" => "From: someone@example.com\r\nSubject: hello\r\n\r\n#{PRIVATE}",
          "text" => PRIVATE,
          "html" => "<p>#{PRIVATE}</p>"
        }
      )
    end

    def post(body, signature:)
      env = Rack::MockRequest.env_for(
        "/inbound/mailersend",
        method: "POST", input: body,
        "CONTENT_TYPE" => "application/json", "HTTP_SIGNATURE" => signature
      )

      status, = MailersendRails::Inbound::Controller.action(:create).call(env)
      status
    end
end
