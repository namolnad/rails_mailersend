# rails_mailersend

MailerSend for Rails: an Action Mailer delivery method, and an optional Action
Mailbox ingress for inbound mail.

This existed as a copied `lib/action_mailer/mailersend_delivery.rb` in four apps.
Three of the copies were identical and one had drifted ahead with typed errors and
a nil-text-part fix — which is the usual shape of copied code, and the reason for
the gem.

## Install

```ruby
gem "rails_mailersend"
```

The name is inverted because `mailersend_rails` on RubyGems is an unrelated gem by
another author, and RubyGems refuses a new name that differs from an existing one
only by its separators — so `mailersend-rails` is out too. Nothing inside moved
for it: the constant is `MailersendRails` in `lib/mailersend_rails.rb`, and
one-line `lib/rails_mailersend.rb` is there so Bundler's auto-require lands
somewhere real without a `require:` option in your Gemfile.

```ruby
# config/environments/production.rb
config.action_mailer.delivery_method = :mailersend
```

That's the whole outbound setup. Adding the gem registers the delivery method; no
initializer and no `require` of a file under `lib/`.

## Configuration

The token is read from Rails credentials, falling back to the environment:

```yaml
# rails credentials:edit
mailersend:
  api_token: ms_...
  inbound_secret: ...   # only for inbound
```

```bash
MAILERSEND_API_TOKEN=ms_...
MAILERSEND_INBOUND_SECRET=...
```

Or set it explicitly:

```ruby
MailersendRails.configure do |config|
  config.api_token = Vault.read("mailersend/token")
  config.log_tag = "inbound"          # prefixes the ingress log lines
  config.header_prefix = "X-Acme-"    # namespaces the headers the ingress stamps
end
```

`header_prefix` defaults to `X-Mailersend-`, and is worth setting once to the
app's own house prefix. The names go into messages that are then stored, so
changing it later leaves every message already on disk answering to a name
nothing reads.

Delivery failures raise `MailersendRails::DeliveryMethod::DeliveryError` rather
than returning quietly, so the enqueuing job retries and the failure is visible.
For an app where sign-in is by magic link, a swallowed delivery error looks
exactly like a broken app to the person waiting.

`In-Reply-To` and `References` are carried across to MailerSend's own
`in_reply_to` and `references` fields, so a reply lands under the message it
answers instead of opening a conversation of its own:

```ruby
mail(to: person.email_address, subject: "Re: #{parent_subject}",
     in_reply_to: parent_message_id, references: [parent_message_id])
```

Angle brackets are put back on, since the `mail` gem strips them and MailerSend
validates against the RFC 5322 form. Every other header is dropped: the API takes
fields rather than a MIME message, and these are the two worth translating. Both
are paid-plan only at MailerSend, which answers a free account carrying them with
a 422 — loudly, rather than with an unthreaded reply nobody can account for.

## Link and open tracking

MailerSend can rewrite every link in a message to a redirector on its own domain. For
marketing mail that is the point. For a message carrying a credential it is two problems at
once: the token is handed to a third party and kept in their click reporting, and the
rewritten URL is no longer yours — so an iOS Universal Link stops matching your
`apple-app-site-association` and opens a browser instead of your app. For a single-use
sign-in link that means it is spent somewhere the app cannot see it.

Set the switches per message, on the mailer that needs them:

```ruby
class SessionMailer < ApplicationMailer
  def sign_in(user)
    headers["X-MailerSend-Track-Clicks"] = "false"
    mail to: user.email, subject: "Your sign-in link"
  end
end
```

| Header | MailerSend field |
|---|---|
| `X-MailerSend-Track-Clicks` | `settings.track_clicks` |
| `X-MailerSend-Track-Opens` | `settings.track_opens` |
| `X-MailerSend-Track-Content` | `settings.track_content` |

Each takes `"true"` or `"false"`, case-insensitively. A message that sets none says nothing
about tracking, and MailerSend falls back to the domain's own setting — so this changes
nothing for the mail you already send.

A value that is neither raises, rather than being quietly dropped. The caller asking for
tracking off is usually sending a credential, and the failure mode of guessing is a token
routed through a redirector without anybody noticing.

## Inbound mail

Optional, and only loads when the app has Action Mailbox. MailerSend posts the
complete RFC822 message, so unlike the Mailgun or Postmark ingresses there is
nothing to rebuild — this hands the message straight to Action Mailbox and lets
`ApplicationMailbox` routing decide what it is.

```ruby
# app/controllers/inbound/mailersend_controller.rb
class Inbound::MailersendController < MailersendRails::Inbound::Controller
end

# config/routes.rb
post "inbound/mailersend" => "inbound/mailersend#create"
```

Point a MailerSend inbound route at that URL and put the route's secret in
`mailersend.inbound_secret`.

Five things it handles that are easy to get wrong:

**The validation ping is answered before the secret is checked.** A route's secret
is generated when the route is saved, so there is no secret to configure until the
route exists — and the route cannot exist while the endpoint refuses the ping for
want of one. Answering first breaks the deadlock. It is safe because it does
nothing: no message read, nothing created, nothing disclosed.

**Envelope recipients are stamped onto the message as `X-Original-To`.** Routing
keys on the recipient, and the headers frequently do not carry it: a sender who
Bccs you leaves no header at all, because stripping Bcc in transit is the entire
point of Bcc. The address survives only in the SMTP envelope. This is the same
move Action Mailbox's own Postmark ingress makes.

**Envelope addresses are filtered before being written into headers.** Header
injection would otherwise be one crafted address away — an address containing a
newline could add arbitrary headers, or close the header block and forge a body.

**MailerSend's SPF and DKIM verdicts are stamped on as `<prefix>SPF` and
`<prefix>DKIM`.** They are the one part of the payload a forger cannot write: a
`From:` line is whatever the sender typed, and these are the only evidence about
it that arrives from outside the message. Each is normalized to one word from a
fixed list — `pass`, `fail`, `softfail`, `neutral`, or `none` — so nothing in the
payload can put anything else into a header. `none` means MailerSend said nothing,
which is distinguishable from a message that never came through the ingress at
all, since that one has no such header.

**Headers in the ingress's own namespace are cleared off an arriving message
before its own are stamped.** Otherwise a sender supplies the verdict that is
supposed to judge them, or an `X-Original-To` naming somewhere the message was
never delivered. The whole prefix is reserved, and so is `X-Original-To`. A
message carrying none of them is passed through byte for byte.

The signature is verified against the exact bytes MailerSend signed, before
anything parses them; checking against a re-serialised body would verify our own
JSON encoder rather than the sender.

## Tests

```bash
bundle exec rake test
```

The parts most worth getting right — the payload guard rails and signature
verification — are plain Ruby and tested without a Rails app.
