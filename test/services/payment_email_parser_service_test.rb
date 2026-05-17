require "test_helper"
require "mail"

class PaymentEmailParserServiceTest < ActiveSupport::TestCase
  def read_eml_fixture(filename)
    File.read(Rails.root.join("test/fixtures/emails", filename))
  end

  def extract_body_text(mail)
    raw_body = if mail.multipart?
      if mail.text_part&.body&.present?
        mail.text_part.decoded
      elsif mail.html_part&.body&.present?
        mail.html_part.decoded
      else
        ""
      end
    else
      mail.decoded
    end

    if mail.content_type&.include?("html") || (mail.multipart? && mail.text_part.nil? && mail.html_part.present?)
      ActionController::Base.helpers.strip_tags(raw_body)
    else
      raw_body
    end
  end

  test "parses Chase Zelle rent payment email correctly" do
    raw_source = read_eml_fixture("zelle-rent-payment.eml")
    mail = Mail.read_from_string(raw_source)
    body_text = extract_body_text(mail)

    parser = PaymentEmailParserService.new(subject: mail.subject, body: body_text)
    parsed = parser.parse

    assert_equal "zelle", parsed[:provider]
    assert_equal "KRISTINA M PAGE", parsed[:sender_name]
    assert_equal BigDecimal("1200.00"), parsed[:amount]
    assert_equal Date.parse("Jul 31, 2024"), parsed[:payment_date]
    assert_equal "21569265114", parsed[:transaction_id]
  end

  test "parses Chase Zelle utility payment email correctly" do
    raw_source = read_eml_fixture("zelle-utility-payment.eml")
    mail = Mail.read_from_string(raw_source)
    body_text = extract_body_text(mail)

    parser = PaymentEmailParserService.new(subject: mail.subject, body: body_text)
    parsed = parser.parse

    assert_equal "zelle", parsed[:provider]
    assert_equal "KRISTINA M PAGE", parsed[:sender_name]
    assert_equal BigDecimal("240.92"), parsed[:amount]
    assert_equal Date.parse("Aug 13, 2024"), parsed[:payment_date]
    assert_equal "21712657537", parsed[:transaction_id]
  end

  test "parses Venmo rent payment email correctly" do
    raw_source = read_eml_fixture("venmo-rent-payment.eml")
    mail = Mail.read_from_string(raw_source)
    body_text = extract_body_text(mail)

    parser = PaymentEmailParserService.new(subject: mail.subject, body: body_text)
    parsed = parser.parse

    assert_equal "venmo", parsed[:provider]
    assert_equal "samantha sanchez", parsed[:sender_name]
    assert_equal BigDecimal("1000.00"), parsed[:amount]
    assert_equal Date.parse("Mar 29, 2024"), parsed[:payment_date]
    assert_equal "4034689063827771191", parsed[:transaction_id]
  end

  test "raises UnknownProviderError when provider cannot be detected" do
    assert_raises PaymentEmailParserService::UnknownProviderError do
      PaymentEmailParserService.new(subject: "Hello", body: "No payment info here").parse
    end
  end
end
