module ApplicationHelper
  # Destination for an activity row: the source record's own page when it has
  # one, otherwise the journal entry. SecurityDeposit is routed only as a
  # singular resource nested under its tenancy, so it cannot go through
  # polymorphic_path.
  def activity_source_path(row)
    source = row.source
    case source
    when Receipt, Charge, Expense, SecurityDepositTransaction
      polymorphic_path(source)
    when SecurityDeposit
      tenancy_security_deposit_path(source.tenancy)
    else
      journal_entry_path(row.journal_entry)
    end
  end
end
