# frozen_string_literal: true

module MailersendRails
  module Inbound
    # Every email that arrives, from anywhere, for any reason.
    #
    # This is an ingress, not a feature: it knows nothing about what the mail is
    # for. MailerSend posts the message as JSON, `data.raw` is the complete RFC822
    # message, and this hands it to Action Mailbox. `ApplicationMailbox` routing
    # then decides what the message *is*. A second kind of inbound mail becomes a
    # new mailbox and one routing line, not a second endpoint, second secret and
    # second DNS record.
    #
    # Mount it in the host app:
    #
    #   class Inbound::MailersendController < MailersendRails::Inbound::Controller
    #   end
    #
    #   post "inbound/mailersend" => "inbound/mailersend#create"
    #
    # Deliberately not the app's own base class: an ingress has no session, no
    # tenancy and no browser, and a modern-browser gate would answer a webhook
    # with 406.
    #
    # And deliberately not ActionController::Base either, but Metal. Base's
    # instrumentation parses the body into params before any callback runs and
    # writes them to the request log -- which here is every message that
    # arrived, whole, in `data.raw`, including the ones refused for a forged
    # signature, since anybody can post one. Nothing below reads `params`: the
    # signature has to be checked against the raw bytes anyway. So on Metal the
    # body is never parsed and there is nothing to log. What that costs is the
    # "Processing by" and "Completed" lines, so what happened to each post is
    # logged here instead, with nothing from the message in it.
    class Controller < ActionController::Metal
      include AbstractController::Callbacks

      # Order matters. The validation ping is answered before the secret is
      # required, because the two deadlock otherwise -- see answer_validation_ping.
      before_action :answer_validation_ping
      before_action :require_secret
      before_action :verify_signature

      def create
        return reject("posted a body we couldn't read as a JSON object") unless payload.parseable?
        return reject("posted a message with no raw MIME") unless payload.raw_message?

        # Rescues RecordNotUnique internally and returns nil, so a retried webhook
        # is already a no-op here.
        inbound_email = ActionMailbox::InboundEmail.create_and_extract_message_id!(
          payload.message_with_transport_headers
        )
        if inbound_email
          log(:info, "stored inbound email #{inbound_email.id}")
        else
          log(:info, "already had that message; ignored the repeat")
        end

        head :no_content
      end

      private
        # MailerSend checks a new route by posting {"type": "webhook.test"}.
        #
        # It has to be answered before the secret is checked, because the two
        # deadlock: a route's secret is generated when the route is saved, so
        # there is no secret to configure until the route exists, and the route
        # cannot exist while we refuse the ping for want of one.
        #
        # Safe because it does nothing -- no message is read, nothing is created,
        # nothing is disclosed. Its signature is deliberately not verified, since
        # MailerSend signs the test with a secret published in their own docs, so
        # checking it would prove nothing about who sent it.
        def answer_validation_ping
          return unless payload.validation_ping?

          log(:info, "answered a validation ping")
          head :ok
        end

        # Fails closed, and loudly. An unconfigured secret would otherwise make
        # every comparison fail against an empty key -- indistinguishable in the
        # log from a provider misconfiguration, and the fix is entirely different.
        def require_secret
          return if MailersendRails.config.inbound_secret?

          log(:error, "no inbound secret configured; refusing inbound mail")
          head :service_unavailable
        end

        def verify_signature
          return if Signature.valid?(
            secret: MailersendRails.config.inbound_secret,
            body: request.raw_post,
            given: request.headers["Signature"]
          )

          log(:warn, "rejected an inbound post with a bad signature")
          head :unauthorized
        end

        def payload
          @payload ||= Payload.parse(request.raw_post)
        end

        def reject(reason)
          log(:warn, reason)
          head :unprocessable_content
        end

        def log(level, message)
          Rails.logger.public_send(level, "[#{MailersendRails.config.log_tag}] #{message}")
        end

        # A status and nothing else, which is all MailerSend reads. Not
        # ActionController::Head, which picks a content type from the view
        # layer's formats, and Metal has no view layer.
        def head(status)
          self.status = status
          self.response_body = ""
        end
    end
  end
end
