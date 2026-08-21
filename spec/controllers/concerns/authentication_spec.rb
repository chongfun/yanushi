require "rails_helper"

RSpec.describe Authentication, type: :controller do
  controller(ApplicationController) do
    allow_unauthenticated_access only: %i[sign_out_test]

    def sign_out_test
      terminate_session
      render plain: "signed out"
    end
  end

  it "terminates session safely when Current.session is nil" do
    routes.draw { post "sign_out_test" => "anonymous#sign_out_test" }

    post :sign_out_test
    expect(response.body).to eq("signed out")
    expect(cookies[:session_id]).to be_blank
  end
end
