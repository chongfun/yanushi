require 'rails_helper'

RSpec.describe "Sessions", type: :system do
  let!(:user) { create(:user) }

  it "shows toast notification on unsuccessful login" do
    visit new_session_path

    fill_in "email", with: "wrong@example.com"
    fill_in "password", with: "wrongpassword"
    click_on "Sign in"

    expect(page).to have_selector(".toast", text: "Try another email address or password.")
    expect(page).to have_selector(".alert-error")
  end

  it "redirects appropriately on successful login" do
    visit new_session_path

    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"

    expect(page).to have_current_path(root_path)
  end
end
