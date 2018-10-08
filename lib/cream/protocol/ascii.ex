defmodule Cream.Protocol.Ascii do

  alias Cream.Coder
  alias Cream.Protocol.Reason

  def flush(socket, options) do
    ["flush_all"]
    |> append(options[:delay])
    |> append("\r\n", :trim)
    |> socket_send(socket)

    recv_line(socket)
  end

  def set(socket, {key, value}, options) do
    build_store_command("set", key, value, options)
    |> socket_send(socket)

    recv_line(socket)
  end

  def set(socket, keys_and_values, options) do
    keys_and_values
    |> Enum.map(fn {key, value} -> build_store_command("set", key, value, options) end)
    |> socket_send(socket)

    errors = Enum.reduce(keys_and_values, %{}, fn {key, _value}, acc ->
      case recv_line(socket) do
        {:error, reason} -> Map.put(acc, key, reason)
        _ -> acc
      end
    end)

    if errors == %{} do
      {:ok, :stored}
    else
      {:error, errors}
    end
  end

  def add(socket, {key, value}, options) do
    build_store_command("add", key, value, options)
    |> socket_send(socket)

    recv_line(socket)
  end

  def add(socket, keys_and_values, options) do
    keys_and_values
    |> Enum.map(fn {key, value} -> build_store_command("add", key, value, options) end)
    |> socket_send(socket)

    errors = Enum.reduce(keys_and_values, %{}, fn {key, _value}, acc ->
      case recv_line(socket) do
        {:error, reason} -> Map.put(acc, key, reason)
        _ -> acc
      end
    end)

    if errors == %{} do
      {:ok, :stored}
    else
      {:error, errors}
    end
  end

  def replace(socket, {key, value}, options) do
    build_store_command("replace", key, value, options)
    |> socket_send(socket)

    recv_line(socket)
  end

  def replace(socket, keys_and_values, options) do
    build_store_commmands("replace", keys_and_values, options)
    |> socket_send(socket)

    errors = Enum.reduce(keys_and_values, %{}, fn {key, _value}, acc ->
      case recv_line(socket) do
        {:error, reason} -> Map.put(acc, key, reason)
        _ -> acc
      end
    end)

    if errors == %{} do
      {:ok, :stored}
    else
      {:error, errors}
    end
  end

  def get(socket, keys, options) when is_list(keys) do
    Enum.reduce(keys, ["get"], &append(&2, &1))
    |> append("\r\n", :trim)
    |> socket_send(socket)

    recv_values(socket, options[:coder])
  end

  def get(socket, key, options) do
    case get(socket, [key], options) do
      {:ok, values} -> {:ok, values[key]}
      error -> error
    end
  end

  def delete(socket, keys, _options) when is_list(keys) do
    Enum.map(keys, &"delete #{&1}\r\n")
    |> socket_send(socket)

    errors = Enum.reduce(keys, %{}, fn key, acc ->
      with {:ok, line} <- recv_line(socket) do
        case line do
          :deleted -> acc
          reason -> Map.put(acc, key, reason)
        end
      else
        {:error, reason} -> Map.put(acc, key, reason)
      end
    end)

    if errors == %{} do
      {:ok, :deleted}
    else
      {:error, errors}
    end
  end

  def delete(socket, key, options) do
    case delete(socket, [key], options) do
      {status, %{^key => reason}} -> {status, reason}
      result -> result
    end
  end

  defp build_store_commmands(cmd, keys_and_values, options) do
    keys_and_values
    |> Enum.map(fn {key, value} -> build_store_command(cmd, key, value, options) end)
  end

  defp build_store_command(cmd, key, value, options) do
    {flags, value} = Coder.encode(options[:coder], value)
    exptime = options[:ttl]
    bytes = byte_size(value)

    [cmd]
    |> append(key)
    |> append(flags)
    |> append(exptime)
    |> append(bytes)
    |> append(options[:cas])
    |> append(options[:noreply] && "noreply")
    |> append("\r\n", :trim)
    |> append(value, :trim)
    |> append("\r\n", :trim)
  end

  defp append(command, arg, trim \\ nil)
  defp append(command, nil, _trim), do: command
  defp append(command, "", _trim), do: command
  defp append(command, arg, nil), do: [command, " ", to_string(arg)]
  defp append(command, arg, :trim), do: [command, to_string(arg)]

  defp chomp(line), do: String.replace_suffix(line, "\r\n", "")

  defp recv_line(socket) do
    :ok = :inet.setopts(socket, packet: :line)
    with {:ok, line} = :gen_tcp.recv(socket, 0) do
      case chomp(line) do
        <<"SERVER_ERROR ", reason::binary>> -> {:error, reason}
        <<"CLIENT_ERROR ", reason::binary>> ->
          # I think this is a bug in memcached; any CLIENT_ERROR <reason>\r\n is followed by
          # an ERROR\r\n. This is not the case for SERVER_ERROR <reason>\r\n lines.
          case :gen_tcp.recv(socket, 0) do
            {:ok, "ERROR\r\n"} -> {:error, reason}
            error -> error
          end
        "STORED"      -> {:ok,    Reason.tr("STORED")}
        "NOT_STORED"  -> {:error, Reason.tr("NOT_STORED")}
        "EXISTS"      -> {:error, Reason.tr("EXISTS")}
        "NOT_FOUND"   -> {:error, Reason.tr("NOT_FOUND")}
        "DELETED"     -> {:ok,    Reason.tr("DELETED")}
        line -> {:ok, line}
      end
    end
  end

  defp recv_values(socket, coder, values \\ %{}) do
    with {:ok, line} <- recv_line(socket),
      {:ok, key, flags, value} <- recv_value(socket, line)
    do
      value = Coder.decode(coder, flags, value)
      values = Map.put(values, key, value)
      recv_values(socket, coder, values)
    else
      :end -> {:ok, values}
      error -> error
    end
  end

  defp recv_value(socket, line) do
    case String.split(line, " ") do
      ["END"] -> :end
      ["VALUE", key, flags, bytes, cas] ->
        case recv_bytes(socket, bytes) do
          {:ok, value} -> {:ok, key, flags, {value, cas}}
          error -> error
        end
      ["VALUE", key, flags, bytes] ->
        case recv_bytes(socket, bytes) do
          {:ok, value} -> {:ok, key, flags, value}
          error -> error
        end
    end
  end

  defp recv_bytes(socket, n) do
    :ok = :inet.setopts(socket, packet: :raw)
    n = String.to_integer(n)
    case :gen_tcp.recv(socket, n + 2) do
      {:ok, data} -> {:ok, chomp(data)}
      error -> error
    end
  end

  defp socket_send(data, socket) do
    :ok = :gen_tcp.send(socket, data)
  end

end
