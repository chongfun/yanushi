require "rails_helper"

RSpec.describe "Properties", type: :system do
  let!(:user) { create(:user) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  let!(:property) { create(:property, user: user, address: "123 Main St") }

  it "navigates across property workspace tabs with history and direct entry", js: true do
    visit property_path(property)
    expect(page).to have_text("123 Main St")
    expect(page).to have_text("Units")

    # Navigate via tabs
    click_on "Tenancies"
    expect(page).to have_css(".yn-tab[aria-current='page']", text: "Tenancies", wait: 5)
    expect(page).to have_current_path(property_tenancies_path(property))

    click_on "Activity"
    expect(page).to have_css(".yn-tab[aria-current='page']", text: "Activity", wait: 5)
    expect(page).to have_current_path(property_activity_path(property))

    click_on "Tax"
    expect(page).to have_css(".yn-tab[aria-current='page']", text: "Tax", wait: 5)
    expect(page).to have_current_path(property_tax_path(property))

    # Test browser Back navigation
    page.go_back
    expect(page).to have_css(".yn-tab[aria-current='page']", text: "Activity", wait: 5)
    expect(page).to have_current_path(property_activity_path(property))

    page.go_back
    expect(page).to have_css(".yn-tab[aria-current='page']", text: "Tenancies", wait: 5)
    expect(page).to have_current_path(property_tenancies_path(property))

    page.go_back
    expect(page).to have_css(".yn-tab[aria-current='page']", text: "Overview", wait: 5)
    expect(page).to have_current_path(property_path(property))

    # Test browser Forward navigation
    page.go_forward
    expect(page).to have_css(".yn-tab[aria-current='page']", text: "Tenancies", wait: 5)
    expect(page).to have_current_path(property_tenancies_path(property))

    page.go_forward
    expect(page).to have_css(".yn-tab[aria-current='page']", text: "Activity", wait: 5)
    expect(page).to have_current_path(property_activity_path(property))
    expect(page).to have_button("Apply")

    # Test direct contextual URL entry
    visit property_tax_path(property)
    expect(page).to have_current_path(property_tax_path(property))
    expect(page).to have_text("Tax year")
  end

  it "filters activity ledger in property activity tab" do
    past_year = Date.current.year - 1
    property = create(:property, user: user, address: "999 Ledger St")
    unit = create(:rentable_unit, property: property)
    tenancy = create(:tenancy, rentable_unit: unit, commencement_date: Date.new(past_year, 1, 1))
    create(:rent_term, tenancy: tenancy, amount_cents: 100_000, effective_from: Date.new(past_year, 1, 1))

    Charges::CreateService.call(
      tenancy: tenancy,
      charge_kind: "rent",
      charge_date: Date.current,
      amount_cents: 100_000,
      description: "Current Charge"
    )

    Expenses::CreateService.call(
      property: property,
      expense_kind: "repairs",
      amount_cents: 5000,
      paid_on: Date.new(past_year, 5, 15),
      description: "Past year plumbing"
    )

    visit property_activity_path(property)

    expect(page).to have_text("Rent")
    expect(page).not_to have_text("Past year plumbing")

    # Select past year from dropdown and submit
    select past_year.to_s, from: "Year"
    click_on "Apply"

    expect(page).to have_text("Past year plumbing")
    expect(page).not_to have_text("Rent")
  end

  it "records an expense with property context and redirects to Property Activity" do
    visit property_path(property)
    click_on "Record expense"

    expect(page).to have_current_path(new_property_expense_path(property))
    expect(page).to have_text("123 Main St")

    select "Repairs", from: "Category"
    fill_in "Amount ($)", with: "250.00"
    fill_in "Date Paid", with: Date.current.strftime("%Y-%m-%d")
    fill_in "Vendor / Payee", with: "Ace Plumbing"
    fill_in "Description", with: "Fix bathroom pipe leak"
    click_on "Record Expense"

    expect(page).to have_current_path(property_activity_path(property))
    expect(page).to have_text("Expense was successfully created.")
    expect(page).to have_text("Fix bathroom pipe leak")
    expect(page).to have_text("−$250.00")
  end

  it "contains table overflow horizontally within containers on mobile viewport", js: true do
    page.driver.browser.manage.window.resize_to(375, 812)

    unit1 = create(:rentable_unit, property: property, name: "Unit 1 With Long Description")
    tenancy1 = create(:tenancy, :month_to_month, rentable_unit: unit1, commencement_date: Date.current - 2.months)
    create(:rent_term, tenancy: tenancy1, amount_cents: 245_000, effective_from: Date.current - 2.months)
    create(:tenancy_party, tenancy: tenancy1, party: create(:party, user: user, display_name: "Alexander Montgomery-Smith"))

    Expenses::CreateService.call(
      property: property,
      expense_kind: "repairs",
      amount_cents: 125_000,
      paid_on: Date.current,
      description: "Emergency electrical main repair"
    )

    # 1. Property Overview
    visit property_path(property)
    expect(page).to have_text("Alexander Montgomery-Smith")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true

    # 2. Property Tenancies
    visit property_tenancies_path(property)
    expect(page).to have_text("Alexander Montgomery-Smith")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true

    # 3. Property Activity
    visit property_activity_path(property)
    expect(page).to have_text("Emergency electrical main repair")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true

    # 4. Portfolio
    visit portfolio_path
    expect(page).to have_text("123 Main St")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true

    # 5. Dashboard Overview
    visit root_path
    expect(page).to have_text("Overview")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true
  end

  it "navigates from vacant unit to tenancy creation with unit preselected", js: true do
    vacant_unit = create(:rentable_unit, property: property, name: "Unit Vacant 202")

    visit property_path(property)
    expect(page).to have_text("Unit Vacant 202")
    expect(page).to have_text("Vacant")

    click_on "Create tenancy"
    expect(page).to have_current_path(new_tenancy_path(rentable_unit_id: vacant_unit.id))
    expect(page).to have_select("Select Rentable Unit", selected: "#{vacant_unit.name} (#{vacant_unit.unit_identifier})")
  end

  it "closes property overflow menu on Escape and restores focus", js: true do
    visit property_path(property)

    find("summary", text: "More").click
    expect(page).to have_selector("details[data-controller='menu'][open]")
    expect(page).to have_link("Edit property")

    page.driver.browser.action.send_keys(:escape).perform
    expect(page).to have_no_selector("details[data-controller='menu'][open]")
    expect(page.evaluate_script("document.activeElement === document.querySelector('details[data-controller=\"menu\"] > summary')")).to be true
  end
end
