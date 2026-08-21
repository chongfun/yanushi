require "rails_helper"

RSpec.describe ApplicationController, type: :controller do
  controller do
    allow_unauthenticated_access only: :show

    def index
      render plain: authenticated_user.email
    end

    def show
      render plain: authenticated_user.email
    end
  end

  it "raises RoutingError when authenticated_user is called without an active session" do
    expect { get :show, params: { id: 1 } }.to raise_error(ActionController::RoutingError, "Authentication required")
  end

  it "returns the user when authenticated" do
    user = create(:user)
    session = create(:session, user: user)
    cookies.signed[:session_id] = session.id

    get :index
    expect(response.body).to eq(user.email)
  end
end
