require "rails_helper"

RSpec.describe "Dashboards", type: :system, js: true do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "999 Dashboard Ave") }
  let!(:unit) { create(:rentable_unit, property: property, name: "Unit A") }
  let!(:party) { create(:party, user: user, display_name: "John Tenant") }
  let!(:tenancy) do
    create(:tenancy,
      property: property,
      rentable_unit: unit,
      commencement_date: Date.current - 2.months,
      termination_date: Date.current + 10.months
    )
  end
  let!(:tenancy_party) { create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: tenancy.commencement_date) }
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

    Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "rent",
      amount_cents: 100_000,
      charge_date: Date.current - 10.days
    )

    Expenses::CreateService.call(
      property: property,
      expense_kind: "repairs",
      amount_cents: 25_000,
      paid_on: Date.current,
      description: "Fix door"
    )

    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "summarizes portfolio state and renders actionable items on Overview" do
    expect(page).to have_button("Sign out")
    expect(page).to have_text("Overview")
    expect(page).to have_text("999 Dashboard Ave")

    # Attention item for the overdue balance
    expect(page).to have_text("Needs attention")
    expect(page).to have_text("John Tenant is $1,000.00 overdue")
    expect(page).to have_text("Open tenancy →")

    # Metrics (case insensitive to accommodate CSS text-transform)
    expect(page).to have_text(/Properties/i)
    expect(page).to have_text(/Units occupied/i)
    expect(page).to have_text(/Outstanding balances/i)
    expect(page).to have_text(/Net income, YTD/i)
    expect(page).to have_text("$750.00")

    # Recent activity
    expect(page).to have_text("Recent activity")
    expect(page).to have_text("Expense")
    expect(page).to have_text("Rent · Unit A")

    # Click property link
    within("[aria-labelledby='properties-heading']") do
      find("a[href='#{property_path(property)}']").click
    end
    expect(page).to have_current_path(property_path(property))
    expect(page).to have_text("Units")
  end

  it "executes the complete daily attention journey: Overview → attention item → tenancy action", js: true do
    expect(page).to have_text("Needs attention")
    expect(page).to have_text("John Tenant is $1,000.00 overdue")

    # Click the attention action link to enter tenancy context
    click_link "Open tenancy →"
    expect(page).to have_current_path(tenancy_path(tenancy))
    # Wait for the tenancy page itself, not a Turbo preview of it: the Overview
    # attention item also names the tenant.
    expect(page).to have_css("#tenancy_balance", text: "$1,000.00 due")
    expect(page).to have_text("John Tenant")

    # Resolve the balance by recording a receipt
    click_on "Record receipt"
    expect(page).to have_css("dialog#modal[open]")
    expect(page).to have_css("#modal-title", text: "Record receipt")
    expect(page).to have_select("Payer")
    within("form#receipt-form") do
      select "John Tenant", from: "receipt-payer"
    end
    expect(find("#receipt-amount").value.to_f).to eq(1000.0)
    page.execute_script("document.getElementById('receipt-method').value = 'Zelle'")
    page.execute_script("document.querySelector('form#receipt-form').requestSubmit()")

    expect(page).to have_text("Payment recorded successfully.")
    expect(page).to have_text(/settled/i)
    expect(page).to have_no_css("dialog#modal[open]")

    # Return to Overview and verify attention item is cleared
    visit root_path
    expect(page).to have_current_path(root_path)
    expect(page).to have_text("Nothing needs attention.")
    expect(page).to have_no_text("John Tenant is $1,000.00 overdue")
  end
end
