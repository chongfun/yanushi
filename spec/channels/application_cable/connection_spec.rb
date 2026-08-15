require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { create(:user) }
  let(:session) { create(:session, user: user) }

  it "successfully connects with valid session cookie" do
    cookies.signed[:session_id] = session.id
    connect "/cable"
    expect(connection.current_user).to eq(user)
  end

  it "rejects connection without session cookie" do
    expect { connect "/cable" }.to have_rejected_connection
  end

  it "rejects connection with invalid session cookie" do
    cookies.signed[:session_id] = 999_999
    expect { connect "/cable" }.to have_rejected_connection
  end
end
