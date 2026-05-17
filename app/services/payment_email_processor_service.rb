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

    # 7. Try utility payment match first
    utility_payment = try_create_utility_payment(tenant, parsed)
    if utility_payment
      email_record.update!(status: :matched_utility, utility_payment: utility_payment)
      return email_record
    end

    # 8. Fall back to rent payment
    rent_payment = try_create_rent_payment(tenant, parsed)
    if rent_payment
      email_record.update!(status: :matched_rent, rent_payment: rent_payment)
      return email_record
    end

    # 9. No match — create in-app notification
    email_record.update!(status: :unmatched, error_message: "No unpaid utility expense or scheduled rent found for tenant '#{tenant.name}'")
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

  def try_create_utility_payment(tenant, parsed)
    tenant.leases.includes(rental_property: :expenses).each do |lease|
      property = lease.rental_property

      # Find utility expenses that don't already have a linked payment
      utility_expenses = property.expenses
                                 .where(category: :utilities)
                                 .where.not(id: UtilityPayment.where.not(expense_id: nil).select(:expense_id))

      matching_expense = utility_expenses.find do |expense|
        expense.amount == parsed[:amount]
      end

      next unless matching_expense

      return UtilityPayment.create!(
        lease:              lease,
        expense:            matching_expense,
        amount:             parsed[:amount],
        payment_date:       parsed[:payment_date] || Date.current,
        payment_method:     parsed[:provider],
        transaction_number: parsed[:transaction_id]
      )
    end

    nil
  end

  def try_create_rent_payment(tenant, parsed)
    # Find earliest unpaid scheduled rent across all of the tenant's leases
    earliest_unpaid = ScheduledRent
      .joins(lease: :lease_tenants)
      .where(lease_tenants: { tenant_id: tenant.id })
      .where(paid: false)
      .order(:due_date)
      .first

    return nil unless earliest_unpaid

    RentPayment.create!(
      scheduled_rent:     earliest_unpaid,
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
