require "rails_helper"

RSpec.describe "Parties", type: :system do
  let!(:user) { create(:user) }

  before do
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "creates a party successfully" do
    visit parties_path
    click_on "New party"

    fill_in "Legal or display name", with: "Jane Doe"
    select "Individual", from: "Party type"
    fill_in "Email", with: "jane@example.com"
    fill_in "Phone", with: "555-1234"

    click_on "Add party"

    expect(page).to have_text("Party was successfully created")
    expect(page).to have_text("Jane Doe")
  end
end
