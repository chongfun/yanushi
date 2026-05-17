class PaymentEmailProcessorService
  def initialize(raw_source:, user:)
    @raw_source  = raw_source
    @user        = user
  end

  def call
    # 1. Parse raw email via Mail gem
    mail = Mail.read_from_string(@raw_source)
    message_id = mail.message_id

    # 2. Deduplicate
    return if PaymentEmail.exists?(user: @user, message_id: message_id)

    # 3. Extract text and strip HTML tags if multipart or HTML-only
    body_text = extract_body_text(mail)

    # 4. Parse fields
    parsed = PaymentEmailParserService.new(subject: mail.subject, body: body_text).parse

    # 5. Create log record
    email_record = PaymentEmail.create!(
      user:           @user,
      message_id:     message_id,
      sender_name:    parsed[:sender_name],
      amount:         parsed[:amount],
      payment_date:   parsed[:payment_date] || mail.date&.to_date || Date.current,
      transaction_id: parsed[:transaction_id],
      provider:       parsed[:provider],
      raw_body:       @raw_source,
      status:         :pending
    )

    # 6. Resolve tenant
    tenant = resolve_tenant(parsed[:sender_name])
    unless tenant
      email_record.update!(status: :unmatched, error_message: "No tenant found matching '#{parsed[:sender_name]}'")
      create_unmatched_notification(@user, email_record)
      return email_record
    end

    # 7. Try create tenant payment
    tenant_payment = try_create_tenant_payment(tenant, parsed)
    if tenant_payment
      email_record.update!(status: :matched, tenant_payment: tenant_payment)
      return email_record
    end

    # 8. No match — create in-app notification
    email_record.update!(status: :unmatched, error_message: "No active lease found for tenant '#{tenant.name}'")
    create_unmatched_notification(@user, email_record)
    email_record

  rescue => e
    email_record&.update(status: :error, error_message: e.message)
    create_unmatched_notification(@user, email_record) if email_record&.persisted?
    raise
  end

  private

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

    # If it is HTML, strip the tags to get clean plain text
    if mail.content_type&.include?("html") || (mail.multipart? && mail.text_part.nil? && mail.html_part.present?)
      ActionController::Base.helpers.strip_tags(raw_body)
    else
      raw_body
    end
  end

  def resolve_tenant(payer_name)
    return nil if payer_name.blank?

    normalized = payer_name.downcase.strip

    # Check primary name first
    tenant = @user.tenants.find { |t| t.name.downcase == normalized }
    return tenant if tenant

    # Check aliases
    alias_match = TenantAlias.joins(:tenant)
                             .where(tenants: { user_id: @user.id })
                             .find_by("LOWER(tenant_aliases.name) = ?", normalized)
    alias_match&.tenant
  end

  def try_create_tenant_payment(tenant, parsed)
    # Find active leases for this tenant
    active_leases = tenant.leases.where(
      "commencement_date <= :today AND (termination_date IS NULL OR termination_date >= :today)",
      today: Date.current
    ).to_a

    return nil if active_leases.empty?

    # Prefer the lease with the most negative balance, otherwise just use the first active lease
    target_lease = active_leases.min_by { |lease| lease.current_balance }

    TenantPayment.create!(
      lease:              target_lease,
      amount:             parsed[:amount],
      payment_date:       parsed[:payment_date] || Date.current,
      payment_method:     parsed[:provider],
      transaction_number: parsed[:transaction_id]
    )
  end

  def create_unmatched_notification(user, email_record)
    Notification.create!(
      user: user,
      title: "Unmatched payment email",
      message: "A #{email_record.provider} payment of #{email_record.amount} from '#{email_record.sender_name}' could not be matched.",
      notification_type: :payment_unmatched,
      read: false,
      payment_email: email_record
    )
  end
end
