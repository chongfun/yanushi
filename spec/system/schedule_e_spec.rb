require "rails_helper"

RSpec.describe "ScheduleE", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "Test Isolation St", asset_type: "multifamily") }
  let!(:unit) { create(:rentable_unit, property: property) }
  let!(:party) { create(:party, user: user) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "verifies schedule e summary accuracy with all expense categories and tax profile", :js do
    year = Date.current.year
    create(:property_tax_profile, property: property, tax_year: year, schedule_e_property_type: "multi_family_residence")

    tenancy = create(:tenancy,
      rentable_unit: unit,
      commencement_date: Date.new(year, 1, 1),
      termination_date: Date.new(year, 12, 31),
      agreement_type: "fixed_term"
    )
    create(:tenancy_party, tenancy: tenancy, party: party)
    create(:rent_term, tenancy: tenancy, effective_from: Date.new(year, 1, 1), effective_until: Date.new(year, 12, 31))

    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 500_000,
      received_on: Date.new(year, 1, 5),
      payment_method: "zelle"
    )

    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 15_000,
      received_on: Date.new(year, 2, 10),
      payment_method: "check"
    )

    categories = Expense::EXPENSE_KINDS

    total_expenses = 0
    categories.each_with_index do |kind, index|
      amount = 100.00 + (index * 10)
      total_expenses += amount
      Expenses::CreateService.call(
        property: property,
        expense_kind: kind,
        amount_cents: (amount * 100).to_i,
        paid_on: Date.new(year, 3, 1),
        description: "Test #{kind}"
      )
    end

    visit schedule_e_property_path(property, year: year)

    expect(page).to have_text("Schedule E — #{year}")
    expect(page).to have_text("Rents received")
    expect(page).to have_text("$5,150.00")
    expect(page).to have_text("Multi family residence")

    categories.each_with_index do |_kind, index|
      amount = 100.00 + (index * 10)
      formatted_amount = ActionController::Base.helpers.number_to_currency(amount)
      expect(page).to have_text(formatted_amount)
    end

    formatted_total_expenses = ActionController::Base.helpers.number_to_currency(total_expenses)
    expect(page).to have_text("Total expenses")
    expect(page).to have_text(formatted_total_expenses)

    net_income = 5150.00 - total_expenses
    formatted_net = ActionController::Base.helpers.number_to_currency(net_income.abs)

    expect(page).to have_text("Net income")
    expect(page).to have_text(formatted_net)

    # When viewing 2026 (template unavailable): PDF button is disabled
    expect(page).to have_button("Download PDF", disabled: true)

    # When viewing 2025 (template available): PDF button is enabled as a download link
    create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence")
    visit schedule_e_property_path(property, year: 2025)
    expect(page).to have_link("Download PDF")
  end

  it "allows resolving a tax review item in the UI to unblock PDF export", :js do
    create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence")
    deposit_account = user.accounts.find_by!(key: "security_deposits_held")
    receivable_account = user.accounts.find_by!(key: "tenant_receivable")

    entry = create(
      :journal_entry,
      user: user,
      occurred_on: Date.new(2025, 6, 15),
      description: "Security deposit applied to charge",
      event_type: "deposit_applied",
      source: property
    )
    create(:posting, journal_entry: entry, account: deposit_account, property: property, amount_cents: 50_000)
    create(:posting, journal_entry: entry, account: receivable_account, property: property, amount_cents: -50_000)

    visit schedule_e_property_path(property, year: 2025)

    expect(page).to have_text("Needs review")
    expect(page).to have_text("1 item needs review")
    expect(page).to have_button("Download PDF", disabled: true)

    # Resolve with default "Include in rents received (Line 3)"
    within("#review_item_#{entry.id}") do
      find("input[type='submit']").click
    end

    expect(page).to have_text("was successfully recorded.", wait: 10)
    expect(page).to have_text("included in Line 3 Rents")
    expect(page).to have_link("Download PDF")
  end

  it "allows mapping an unmapped expense item to a Schedule E category in the UI to unblock PDF export", :js do
    create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence")
    unmapped_account = user.accounts.create!(name: "Custom Roof", key: "expense_custom_roof", account_type: "expense")
    expense = create(:expense, property: property, expense_kind: "other", amount_cents: 800_000)
    entry = create(
      :journal_entry,
      user: user,
      occurred_on: Date.new(2025, 4, 1),
      description: "New roof installation",
      event_type: "expense_posted",
      source: expense
    )
    create(:posting, journal_entry: entry, account: unmapped_account, property: property, amount_cents: 800_000)

    visit schedule_e_property_path(property, year: 2025)

    expect(page).to have_text("Needs review")
    expect(page).to have_text("Unmapped expense account 'Custom Roof'")

    within("#schedule_e_review") do
      select "Repairs", from: "Category"
      click_on "Resolve"
    end

    expect(page).to have_text("was successfully recorded.", wait: 10)
    expect(page).to have_text("mapped to Repairs")
    expect(page).to have_link("Download PDF")
  end

  it "allows excluding an unknown complex event with mapped expenses in the UI without affecting Schedule E expense lines", :js do
    create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence")
    cash_account = user.accounts.find_by!(key: "cash")
    repairs_account = user.accounts.find_by!(key: "expense_repairs")
    equity_account = user.accounts.find_by!(key: "opening_balance_equity")

    entry = create(
      :journal_entry,
      user: user,
      occurred_on: Date.new(2025, 7, 1),
      description: "Complex settlement with repairs and cash",
      event_type: "complex_settlement",
      source: property
    )
    create(:posting, journal_entry: entry, account: repairs_account, property: property, amount_cents: 10_000) # $100
    create(:posting, journal_entry: entry, account: cash_account, property: property, amount_cents: 90_000)    # $900
    create(:posting, journal_entry: entry, account: equity_account, property: property, amount_cents: -100_000) # -$1,000

    visit schedule_e_property_path(property, year: 2025)

    expect(page).to have_text("Needs review")

    within("#schedule_e_review") do
      select "Exclude from Schedule E", from: "Treatment"
      click_on "Resolve"
    end

    expect(page).to have_text("was successfully recorded.", wait: 10)
    expect(page).to have_text("excluded from Schedule E")
    expect(page).to have_link("Download PDF")
  end

  it "displays validation error banner and preserves form selections when mapping category is omitted", :js do
    create(:property_tax_profile, property: property, tax_year: 2025, schedule_e_property_type: "single_family_residence")
    unmapped_account = user.accounts.create!(name: "Custom Roof", key: "expense_custom_roof", account_type: "expense")
    expense = create(:expense, property: property, expense_kind: "other", amount_cents: 800_000)
    entry = create(
      :journal_entry,
      user: user,
      occurred_on: Date.new(2025, 4, 1),
      description: "New roof installation",
      event_type: "expense_posted",
      source: expense
    )
    create(:posting, journal_entry: entry, account: unmapped_account, property: property, amount_cents: 800_000)

    visit schedule_e_property_path(property, year: 2025)

    expect(page).to have_text("Needs review")

    # Choose map to category without selecting a category
    within("#schedule_e_review") do
      select "Map to a Schedule E expense category", from: "Treatment"
      click_on "Resolve"
    end

    # Verifies error banner is displayed, no false success toast, and form inputs are preserved
    expect(page).to have_css(".yn-alert-danger", text: "Schedule e category can't be blank", wait: 5)
    expect(page).not_to have_text("was successfully recorded.")
    within("#schedule_e_review") do
      expect(page).to have_select("Treatment", selected: "Map to a Schedule E expense category")
    end
  end
end
