module AuthenticationHelper
  def sign_in_as(user)
    session = user.sessions.create!(
      user_agent: "TestAgent",
      ip_address: "127.0.0.1"
    )
    if respond_to?(:cookies)
      ActionDispatch::TestRequest.create.cookie_jar.tap do |cookie_jar|
        cookie_jar.signed[:session_id] = session.id
        cookies["session_id"] = cookie_jar[:session_id]
      end
    elsif respond_to?(:visit)
      visit new_session_path
      fill_in "email", with: user.email
      fill_in "password", with: "password"
      click_on "Sign in"
    end
    session
  end

  def sign_out
    if respond_to?(:cookies)
      cookies.delete("session_id")
    elsif respond_to?(:visit)
      page.driver.browser.manage.delete_cookie("session_id") rescue nil
    end
    Current.session&.destroy!
  end
end

RSpec.configure do |config|
  config.include AuthenticationHelper, type: :request
  config.include AuthenticationHelper, type: :system
end
