module NavigationHelper
  PRIMARY_ITEMS = [
    { key: :overview,  label: "Overview",  path_helper: :root_path },
    { key: :portfolio, label: "Portfolio", path_helper: :portfolio_path },
    { key: :money,     label: "Money",     path_helper: :money_path },
    { key: :inbox,     label: "Inbox",     path_helper: :inbox_path },
    { key: :reports,   label: "Reports",   path_helper: :reports_path }
  ].freeze

  def active_primary_navigation_key
    path = request.path

    if path == "/"
      :overview
    elsif path.match?(%r{\A/properties/\d+/schedule_e})
      :reports
    elsif path.match?(%r{\A/reports(\z|/)})
      :reports
    elsif path.match?(%r{\A/(portfolio|properties|tenancies|parties|rentable_units)(\z|/)})
      :portfolio
    elsif path.match?(%r{\A/(money|receipts|expenses|charges|security_deposit_transactions)(\z|/)})
      :money
    elsif path.match?(%r{\A/(inbox|imported_transactions|source_documents)(\z|/)})
      :inbox
    elsif path.match?(%r{\A/(accounts|journal_entries)(\z|/)})
      :accounting
    end
  end

  def primary_navigation_item_active?(key)
    active_primary_navigation_key == key.to_sym
  end

  def inbox_reviewable_count
    return @inbox_reviewable_count if defined?(@inbox_reviewable_count)

    user = Current.user
    @inbox_reviewable_count = user ? user.imported_transactions.reviewable.count : 0
  end
end
