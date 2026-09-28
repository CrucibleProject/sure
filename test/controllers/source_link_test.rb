require "test_helper"

class SourceLinkTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    Sure.stubs(:commit_sha).returns("0123456789abcdef0123456789abcdef01234567")
  end

  test "user menu links the running commit to upstream by default" do
    with_self_hosting do
      with_env_overrides("SOURCE_REPOSITORY_URL" => nil) do
        get root_path
      end
    end

    assert_response :ok
    assert_select "a[href=?]", "https://github.com/we-promise/sure/commit/0123456789abcdef0123456789abcdef01234567"
  end

  test "user menu links the running commit to the configured source repository" do
    with_self_hosting do
      with_env_overrides("SOURCE_REPOSITORY_URL" => "https://github.com/example/sure") do
        get root_path
      end
    end

    assert_response :ok
    assert_select "a[href=?]", "https://github.com/example/sure/commit/0123456789abcdef0123456789abcdef01234567"
    assert_select "a[href*=?]", "we-promise/sure/commit/", count: 0
  end
end
