module FormattingHelper
  def format_money_cents(cents)
    return "$0.00" if cents.nil?

    ActiveSupport::NumberHelper.number_to_currency(cents / 100.0)
  end

  def signed_money_cents(cents, plus: false)
    return "$0.00" if cents.nil? || cents.zero?

    if cents.negative?
      "\u2212#{format_money_cents(cents.abs)}"
    elsif plus
      "+#{format_money_cents(cents)}"
    else
      format_money_cents(cents)
    end
  end

  def balance_phrase_cents(cents)
    return "Settled" if cents.nil? || cents.zero?

    if cents.positive?
      "#{format_money_cents(cents)} due"
    else
      "#{format_money_cents(cents.abs)} credit"
    end
  end
end
