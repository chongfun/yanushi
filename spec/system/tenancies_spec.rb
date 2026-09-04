require "rails_helper"

RSpec.describe "Tenancies", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "999 Lease Ave") }
  let!(:unit) { create(:rentable_unit, property: property, name: "Main Unit") }
  let!(:party) { create(:party, user: user, display_name: "Lease Tester") }
  let!(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      agreement_type: "month_to_month",
      commencement_date: Date.current - 1.month,
      late_period_days: 5
    )
  end
  let!(:tenancy_party) do
    create(:tenancy_party,
      tenancy: tenancy,
      party: party,
      role: "tenant",
      effective_from: tenancy.commencement_date
    )
  end
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 100_000,
      effective_from: tenancy.commencement_date,
      due_day: 1
    )
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "creates a month-to-month tenancy and displays its details" do
    vacant_unit = create(:rentable_unit, property: property, name: "Vacant Unit")
    visit tenancies_path

    click_on "New tenancy"

    select vacant_unit.name, from: "Rentable unit"
    check party.display_name

    select "Month To Month", from: "Agreement type"
    fill_in "Commencement date", with: Date.today.to_s
    fill_in "Monthly rent", with: "1000"
    fill_in "Grace period (days)", with: "5"

    click_on "Create tenancy"

    expect(page).to have_text("Tenancy was successfully created")
    expect(page).to have_text("Lease Tester")
    expect(page).to have_text("$1,000.00")
  end

  it "submits invalid dialog data, recovers, closes, and opens another dialog without page refresh", js: true do
    visit tenancy_path(tenancy)
    expect(page).to have_content("Main Unit")

    # Verify Delete tenancy is available on clean active tenancy
    find("summary", text: "More").click
    expect(page).to have_button("Delete tenancy…")
    find("summary", text: "More").click

    # 0. Test close button restores focus to trigger without mutating state
    click_on "Record receipt"
    expect(page).to have_css("dialog#modal[open]")
    expect(page).to have_css("#modal-title", text: "Record receipt")
    expect(page).to have_select("Payer")
    page.execute_script("document.querySelector('button.modal-close').click()")
    expect(page).to have_no_css("dialog#modal[open]")
    expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Record receipt")
    expect(page).to have_current_path(tenancy_path(tenancy))

    # 1. Open Record Receipt dialog
    page.execute_script("document.querySelector('a[href=\"#{new_tenancy_receipt_path(tenancy)}\"]').click()")
    expect(page).to have_css("dialog#modal[open]")
    expect(page).to have_css("#modal-title", text: "Record receipt")

    # 2. Submit invalid data (unselected payer)
    within("form#receipt-form") do
      select "Select payer", from: "receipt-payer"
    end
    page.execute_script("document.getElementById('receipt-amount').value = '500.00'")
    page.execute_script("document.querySelector('form#receipt-form').requestSubmit()")

    # 3. Verify validation error rendered in frame, focus moved to first invalid field, and amount is preserved
    expect(page).to have_css(".yn-alert-danger")
    expect(page).to have_content("Payer party is required")
    expect(page).to have_css("dialog#modal[open]")
    expect(page).to have_css("turbo-frame#modal-frame")
    expect(page.evaluate_script("document.activeElement.id")).to eq("receipt-payer")
    expect(find("#receipt-amount").value.to_f).to eq(500.0)

    # 4. Correct data (selecting payer and adding method, preserving amount) and resubmit
    within("form#receipt-form") do
      select party.display_name, from: "receipt-payer"
    end
    page.execute_script("document.getElementById('receipt-method').value = 'Zelle'")
    page.execute_script("document.querySelector('form#receipt-form').requestSubmit()")

    # 5. Verify modal closes, balance updates, toast appears, focus is restored to trigger, and Delete is immediately suppressed
    expect(page).to have_no_css("dialog#modal[open]")
    expect(page).to have_css("#tenancy_balance", text: "credit")
    expect(page).to have_css("#tenancy_activity", text: "Payment received")
    expect(page).to have_css("#flash-messages", text: "Payment recorded successfully.")
    expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Record receipt")
    expect(page).to have_current_path(tenancy_path(tenancy))

    find("summary", text: "More").click
    expect(page).not_to have_button("Delete tenancy…")
    find("summary", text: "More").click

    # 6. Open Add Charge dialog without refreshing the page
    page.execute_script("document.querySelector('a[href=\"#{new_tenancy_charge_path(tenancy)}\"]').click()")
    expect(page).to have_css("dialog#modal[open]")
    expect(page).to have_css("#modal-title", text: "Add charge")
    expect(page).to have_select("Charge type")

    # 7. Post a valid charge
    within("form#charge-form") do
      select "Late fee", from: "Charge type"
    end
    page.execute_script("document.getElementById('charge-amount').value = '50.00'")
    page.execute_script("document.getElementById('charge-desc').value = 'Late fee for rent'")
    page.execute_script("document.querySelector('form#charge-form').requestSubmit()")

    # 8. Verify modal closes, charge appears in activity, toast appears, and focus is restored
    expect(page).to have_no_css("dialog#modal[open]")
    expect(page).to have_css("#tenancy_activity", text: "Late fee")
    expect(page).to have_css("#flash-messages", text: "Charge posted successfully.")
    expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Add charge")
    expect(page).to have_current_path(tenancy_path(tenancy))

    # 9. Verify URL remains Tenancy Activity, then refresh page and verify persisted balance and activity are identical
    pre_balance = find("#tenancy_balance").text
    pre_activity = find("#tenancy_activity").text

    page.refresh

    expect(page).to have_current_path(tenancy_path(tenancy))
    expect(find("#tenancy_balance").text).to eq(pre_balance)
    expect(find("#tenancy_activity").text).to eq(pre_activity)
    within("#tenancy_balance") do
      expect(page).to have_content("$450.00")
      expect(page).to have_content("credit")
    end
    within("#tenancy_activity") do
      expect(page).to have_content("Payment received")
      expect(page).to have_content("−$500.00")
      expect(page).to have_content("Late fee")
      expect(page).to have_content("$50.00")
    end
  end

  it "comprehends tenancy status, balance, and activity, and navigates between workspaces with browser history", js: true do
    # Setup representative financial activity: $1,000 rent charge, $600 receipt -> $400 due
    Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "rent",
      amount_cents: 100_000,
      charge_date: Date.current.beginning_of_month,
      due_on: Date.current.beginning_of_month,
      service_period_start: Date.current.beginning_of_month,
      service_period_end: Date.current.end_of_month
    )
    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount: 600.0,
      received_on: Date.current,
      payment_method: "Zelle"
    )

    visit tenancy_path(tenancy)

    # 1. Activity tab comprehension: identity, status, rent, amount due, and causal activity
    expect(page).to have_content("Lease Tester · Main Unit")
    expect(page).to have_content("999 Lease Ave")
    expect(page).to have_content("Active")
    expect(page).to have_content("$1,000.00/month")
    expect(page).to have_content("Month-to-month")

    within("#tenancy_balance") do
      expect(page).to have_content("$400.00")
      expect(page).to have_content("due")
    end

    within("#tenancy_activity") do
      expect(page).to have_content("Rent")
      expect(page).to have_content("$1,000.00")
      expect(page).to have_content("Payment received")
      expect(page).to have_content("−$600.00")
    end

    expect(page).to have_css("a.yn-tab[aria-current='page']", text: "Activity")
    expect(page).to have_link("Add charge")
    expect(page).to have_link("Record receipt")

    # Tenancy with financial activity suppresses Delete tenancy action
    find("summary", text: "More").click
    expect(page).not_to have_button("Delete tenancy…")
    find("summary", text: "More").click
    expect(page).to have_no_css("#tenancy_actions details[open]")

    # 2. Navigate to Agreement tab
    click_on "Agreement"
    expect(page).to have_current_path(tenancy_agreement_path(tenancy))
    expect(page).to have_content("Terms")
    expect(page).to have_content("Month to month")
    expect(page).to have_content("5 days")
    expect(page).to have_content("Participants")
    expect(page).to have_content("Lease Tester")
    expect(page).to have_content("Rent")
    expect(page).to have_content("$1,000.00")
    expect(page).to have_content("Current")
    expect(page).to have_link("Change rent")
    expect(page).to have_css("a.yn-tab[aria-current='page']", text: "Agreement")

    # 3. Use browser back button to return to Activity tab
    page.go_back
    expect(page).to have_current_path(tenancy_path(tenancy))
    expect(page).to have_css("#tenancy_balance", text: "$400.00")
    expect(page).to have_css("#tenancy_activity", text: "Rent")
    expect(page).to have_css("a.yn-tab[aria-current='page']", text: "Activity")

    # 4. Use browser forward button to return to Agreement tab
    page.go_forward
    expect(page).to have_current_path(tenancy_agreement_path(tenancy))
    expect(page).to have_content("Terms")
    expect(page).to have_css("a.yn-tab[aria-current='page']", text: "Agreement")
  end

  it "displays past tenancy with final active tenant and suppresses invalid actions", js: true do
    past_unit = create(:rentable_unit, property: property, name: "Historical Unit")
    past_tenancy = create(:tenancy,
      rentable_unit: past_unit,
      commencement_date: Date.current - 1.year,
      termination_date: Date.current - 1.month,
      agreement_type: "fixed_term"
    )
    former_party = create(:party, user: user, display_name: "Former Tenant")
    final_party = create(:party, user: user, display_name: "Final Tenant")

    create(:tenancy_party,
      tenancy: past_tenancy,
      party: former_party,
      role: "tenant",
      effective_from: past_tenancy.commencement_date,
      effective_until: past_tenancy.commencement_date + 6.months
    )
    create(:tenancy_party,
      tenancy: past_tenancy,
      party: final_party,
      role: "tenant",
      effective_from: past_tenancy.commencement_date + 6.months,
      effective_until: past_tenancy.termination_date
    )
    create(:rent_term,
      tenancy: past_tenancy,
      amount_cents: 120_000,
      effective_from: past_tenancy.commencement_date,
      due_day: 1
    )

    visit tenancy_path(past_tenancy)

    # Shows final tenant as of termination in page content and browser title
    expect(page).to have_content("Final Tenant · Historical Unit")
    expect(page).not_to have_content("Former Tenant · Historical Unit")
    expect(page).to have_title(/Final Tenant · Historical Unit/)
    expect(page).to have_content("Ended")

    # Suppresses active action buttons on settled ended tenancy
    expect(page).not_to have_link("Record receipt")
    expect(page).not_to have_link("Add charge")

    # More menu suppresses Change rent and End tenancy
    find("summary", text: "More").click
    expect(page).not_to have_link("Change rent")
    expect(page).not_to have_link("End tenancy…")
    expect(page).to have_button("Delete tenancy…")

    # Agreement page also suppresses Change rent
    visit tenancy_agreement_path(past_tenancy)
    expect(page).not_to have_link("Change rent")
    expect(page).to have_content("Participants")
    expect(page).to have_content("Former Tenant")
    expect(page).to have_content("Final Tenant")

    # When past tenancy has an unpaid balance due, Record receipt remains available
    Charges::CreateFeeService.call(
      tenancy: past_tenancy,
      charge_kind: "other",
      amount_cents: 40_000,
      charge_date: past_tenancy.termination_date,
      due_on: past_tenancy.termination_date,
      description: "Unpaid utility adjustment"
    )

    visit tenancy_path(past_tenancy)
    expect(page).to have_css("#tenancy_balance", text: "$400.00")
    expect(page).to have_link("Record receipt")
    expect(page).not_to have_link("Add charge")

    # Now that charges exist, Delete tenancy is suppressed
    find("summary", text: "More").click
    expect(page).not_to have_button("Delete tenancy…")

    # 1. Partial payment: record $100 -> $300 due, Record receipt remains available and focus is restored to trigger
    click_on "Record receipt"
    expect(page).to have_css("dialog#modal[open]")
    expect(page).to have_css("#modal-title", text: "Record receipt")

    within("form#receipt-form") do
      select "Final Tenant", from: "receipt-payer"
    end
    page.execute_script("document.getElementById('receipt-amount').value = '100.00'")
    page.execute_script("document.getElementById('receipt-method').value = 'Zelle'")
    page.execute_script("document.querySelector('form#receipt-form').requestSubmit()")

    expect(page).to have_no_css("dialog#modal[open]")
    expect(page).to have_css("#flash-messages", text: "Payment recorded successfully.")
    within("#tenancy_balance") do
      expect(page).to have_content("$300.00")
      expect(page).to have_content("due")
    end
    expect(page).to have_link("Record receipt")
    expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Record receipt")

    # 2. Full payoff: record remaining $300 -> $0.00 settled, Record receipt is removed via Turbo Stream without reload
    page.execute_script("document.querySelectorAll('#flash-messages .yn-alert').forEach(el => el.remove())")
    click_on "Record receipt"
    expect(page).to have_css("dialog#modal[open]")

    within("form#receipt-form") do
      select "Final Tenant", from: "receipt-payer"
    end
    page.execute_script("document.getElementById('receipt-method').value = 'Zelle'")
    page.execute_script("document.querySelector('form#receipt-form').requestSubmit()")

    expect(page).to have_no_css("dialog#modal[open]")
    expect(page).to have_css("#tenancy_balance:focus")
    within("#tenancy_balance") do
      expect(page).to have_content("$0.00")
      expect(page).to have_content("settled")
    end

    within("#tenancy_actions") do
      expect(page).not_to have_link("Record receipt")
      expect(page).not_to have_link("Add charge")
    end
  end

  it "displays upcoming tenancy with initial rent rate and suppresses invalid actions", js: true do
    upcoming_unit = create(:rentable_unit, property: property, name: "Upcoming Unit")
    upcoming_tenancy = create(:tenancy,
      rentable_unit: upcoming_unit,
      commencement_date: Date.current + 1.month,
      agreement_type: "month_to_month"
    )
    future_party = create(:party, user: user, display_name: "Future Tenant")
    create(:tenancy_party,
      tenancy: upcoming_tenancy,
      party: future_party,
      role: "tenant",
      effective_from: upcoming_tenancy.commencement_date
    )
    # Initial commencement term ($1,000) and scheduled future increase ($1,200)
    create(:rent_term,
      tenancy: upcoming_tenancy,
      amount_cents: 100_000,
      effective_from: upcoming_tenancy.commencement_date,
      effective_until: upcoming_tenancy.commencement_date + 4.months,
      due_day: 1
    )
    create(:rent_term,
      tenancy: upcoming_tenancy,
      amount_cents: 120_000,
      effective_from: upcoming_tenancy.commencement_date + 4.months + 1.day,
      due_day: 1
    )

    visit tenancy_path(upcoming_tenancy)

    expect(page).to have_content("Future Tenant · Upcoming Unit")
    expect(page).to have_title(/Future Tenant · Upcoming Unit/)
    expect(page).to have_content("Upcoming")
    expect(page).to have_content("$1,000.00/month")

    # Upcoming tenancy without debt suppresses active action buttons
    expect(page).not_to have_link("Record receipt")
    expect(page).not_to have_link("Add charge")

    # More menu exposes valid actions including Change rent, End tenancy, and Delete tenancy
    find("summary", text: "More").click
    expect(page).to have_link("Change rent")
    expect(page).to have_link("End tenancy…")
    expect(page).to have_button("Delete tenancy…")

    # Agreement page displays initial rent rate
    visit tenancy_agreement_path(upcoming_tenancy)
    expect(page).to have_content("Future Tenant")
    expect(page).to have_content("$1,000.00")
  end
end
