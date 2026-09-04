require "rails_helper"

RSpec.describe "Search", type: :system do
  let!(:user) { create(:user) }

  before do
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "finds a tenant from anywhere in the app without knowing which property they are in" do
    property = create(:property, user: user, address: "77 Larkspur Lane")
    unit = create(:rentable_unit, property: property, name: "Upper flat", unit_identifier: "UF")
    tenancy = create(:tenancy, rentable_unit: unit)
    create(:tenancy_party, tenancy: tenancy, party: create(:party, user: user, display_name: "Nadia Osei"))

    visit reports_path

    within("aside.yn-sidebar") do
      fill_in "Search", with: "nadia"
      click_on "Search"
    end

    expect(page).to have_current_path(search_path(q: "nadia"))
    within("section[aria-labelledby='search-group-tenancies']") do
      expect(page).to have_text("77 Larkspur Lane")
      expect(page).to have_text("Nadia Osei")
      expect(page).to have_link(href: tenancy_path(tenancy))
    end

    within("section[aria-labelledby='search-group-parties']") do
      click_on "Nadia Osei"
    end
    expect(page).to have_current_path(party_path(Party.find_by(display_name: "Nadia Osei")))
  end

  it "explains each state: nothing searched, too short, and no matches" do
    create(:property, user: user, address: "77 Larkspur Lane")

    visit search_path
    expect(page).to have_text("Nothing searched yet")
    expect(page).to have_link("Browse portfolio")

    within("main#main") do
      fill_in "Search properties, units, tenancies, and parties", with: "l"
      click_on "Search"
    end
    expect(page).to have_text("Search is too short")
    expect(page).to have_no_text("77 Larkspur Lane")

    within("main#main") do
      fill_in "Search properties, units, tenancies, and parties", with: "quartz"
      click_on "Search"
    end
    expect(page).to have_text("No matches for")
    expect(page).to have_link("Browse portfolio")

    within("main#main") do
      fill_in "Search properties, units, tenancies, and parties", with: "larkspur"
      click_on "Search"
    end
    expect(page).to have_text("77 Larkspur Lane")
  end

  it "caps a group and offers the index for the rest" do
    7.times { |n| create(:property, user: user, address: "#{n} Juniper Way") }

    visit search_path(q: "juniper")

    within("section[aria-labelledby='search-group-properties']") do
      expect(page).to have_text("7 matches")
      expect(page).to have_css("li", count: 5)
      click_on "See all properties"
    end

    expect(page).to have_current_path(portfolio_path)
  end

  it "reaches the search page from the mobile top bar" do
    visit root_path

    within("header.lg\\:hidden") do
      click_on "Search"
    end

    expect(page).to have_current_path(search_path)
    expect(page).to have_text("Nothing searched yet")
  end
end
