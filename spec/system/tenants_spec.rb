require 'rails_helper'

RSpec.describe "Tenants", type: :system do
  let!(:user) { create(:user) }

  before do
    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "creates a tenant successfully" do
    visit tenants_path
    click_on "New tenant"

    fill_in "Primary Legal Name", with: "Jane Doe"
    fill_in "Mailing Address", with: "456 Side St"
    fill_in "Phone Number", with: "555-1234"
    fill_in "Email Address", with: "jane@example.com"

    click_on "Create Tenant"

    expect(page).to have_text("Tenant was successfully created")
    expect(page).to have_text("Jane Doe")
  end
end
