defmodule UmlishWeb.PageControllerTest do
  use UmlishWeb.ConnCase, async: true

  test "GET / renders the viewer", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "View this service's internals"
    assert html_response(conn, 200) =~ "Analyze project"
  end
end
