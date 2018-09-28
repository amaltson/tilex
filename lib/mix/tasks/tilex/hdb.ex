require Logger

defmodule Mix.Tasks.Tilex.Hdb do
  use Mix.Task

  @shortdoc "Replace development PostgreSQL DB with dump from a Heroku app's DB."

  @moduledoc """
  Run `mix tilex.hdb` to copy all data from the production database to the
  development database.
  """

  def run(args) do
    parser =
      Optimus.new!(
        name: "tilex.hdb",
        description: @shortdoc,
        about: @moduledoc,
        options: [
          app: [
            short: "-a",
            long: "--app",
            help: "Source Heroku app name.",
            required: true,
            parser: :string
          ]
        ],
        flags: [
          force: [
            short: "-f",
            long: "--force",
            help: "Continue without user input.",
            default: false
          ]
        ]
      )

    parsed = Optimus.parse!(parser, args)

    if parsed.flags.force or confirm("This will drop your local database. Continue?") do
      replace_local_db_with_heroku_db(parsed.options.app)
    end
  end

  defp confirm(prompt) do
    input = IO.gets(prompt <> " [YyNn] ")
    "y" == input |> String.trim() |> String.downcase()
  end

  defp tmpfile(suffix) do
    case System.cmd("mktemp", ["--suffix", suffix]) do
      {filename, 0} -> {:ok, String.trim(filename)}
      {out, status} -> {:error, {out, status}}
    end
  end

  defp fetch_heroku_dsn(heroku_app) do
    {out, status} =
      System.cmd(
        "heroku",
        [
          "run",
          "-a",
          heroku_app,
          "--no-notify",
          "--no-tty",
          "-x",
          "sh -c 'echo $DATABASE_URL'"
        ]
      )

    case {String.trim(out), status} do
      {"", _} -> {:error, :no_heroku_output}
      {dsn, 0} -> {:ok, dsn}
      {out, status} -> {:error, {out, status}}
    end
  end

  @dsn_pattern ~r|^
    (?<type>.+?)
    ://
    (?<username>.+?)
    :
    (?<password>.*?)
    @
    (?<hostname>.+?)
    :
    (?<port>.+?)
    /
    (?<database>.+)
  $|x

  defp parse_dsn(dsn) do
    case Regex.named_captures(@dsn_pattern, dsn) do
      nil ->
        {:error, :nomatch}

      captures ->
        {:ok, captures |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)}
    end
  end

  defp pg_args(config, args) do
    [
      "-U",
      config[:username],
      "-h",
      config[:hostname],
      "-p",
      config[:port]
    ] ++ args ++ [config[:database]]
  end

  defp pg_env(config) do
    [{"PGPASSWORD", Keyword.get(config, :password, "")}]
  end

  defp pg_dump_to_file(config, filename) do
    args = pg_args(config, ["-f", filename, "--no-acl", "--no-owner"])

    case System.cmd("pg_dump", args, env: pg_env(config)) do
      {_, 0} -> :ok
      {out, status} -> {:error, {out, status}}
    end
  end

  defp psql_import(config, filename) do
    args = pg_args(config, ["-f", filename])

    case System.cmd("psql", args, env: pg_env(config)) do
      {_, 0} -> :ok
      {out, status} -> {:error, {out, status}}
    end
  end

  defp replace_local_db_with_heroku_db(heroku_app) do
    {:ok, tmp} = tmpfile(".sql")

    try do
      Logger.info("Dumping Heroku app `#{heroku_app}` DB to #{tmp}...")
      {:ok, dsn} = fetch_heroku_dsn(heroku_app)
      {:ok, config} = parse_dsn(dsn)
      :ok = pg_dump_to_file(config, tmp)

      Logger.info("Recreating local DB...")
      Mix.Task.run("ecto.drop")
      Mix.Task.run("ecto.create")

      Logger.info("Loading to local DB from #{tmp} ...")
      :ok = psql_import(Tilex.Repo.config(), tmp)
    after
      File.rm!(tmp)
    end
  end
end
