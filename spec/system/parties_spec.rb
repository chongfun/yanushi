require "rails_helper"

RSpec.describe "Parties", type: :system do
  let!(:user) { create(:user) }

  before do
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "creates a party successfully" do
    visit parties_path
    click_on "New Tenant / Payer"

    fill_in "Legal / Display Name", with: "Jane Doe"
    select "Individual", from: "Party Type"
    fill_in "Email Address", with: "jane@example.com"
    fill_in "Phone Number", with: "555-1234"

    click_on "Create Party"

    expect(page).to have_text("Party was successfully created")
    expect(page).to have_text("Jane Doe")
  end
end
