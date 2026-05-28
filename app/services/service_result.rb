ServiceResult = Data.define(:success, :data, :error, :code) do
  def success? = success
  def failure? = !success
end
