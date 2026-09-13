module ImportedTransactionsHelper
  def imported_transaction_alias_proposal(transaction)
    transaction.proposed_alias_for
  end

  def imported_transaction_source_description(transaction)
    desc = if (username = transaction.payer_username) && !username.empty?
      "“#{username}”"
    elsif (raw = transaction.raw_text) && !raw.empty?
      "“#{raw.slice(0, 45)}”"
    elsif (ref = transaction.external_reference) && !ref.empty?
      "“#{ref}”"
    elsif (name = transaction.payer_name) && !name.empty?
      "“#{name}”"
    end

    [ transaction.payment_method&.titleize, desc ].compact.join(" · ")
  end
end
