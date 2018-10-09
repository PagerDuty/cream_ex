defmodule Cream.Protocol.Binary do

  alias Cream.Protocol.Binary.Message
  alias Cream.Protocol.Reason
  alias Cream.Coder

  import Cream.Helper

  def flush(socket, options) do
    Message.iolist(:flush, extras: [ttl: options[:ttl]])
    |> socket_send(socket)

    with {:ok, message} <- recv_message(socket) do
      case message do
        %{status: 0} -> {:ok, :flushed}
        %{value: reason} -> {:error, Reason.tr(reason)}
      end
    end
  end

  def delete(socket, key, options) when not is_list(key) do
    delete(socket, [key], options)
    |> response_for(key)
  end

  def delete(socket, keys, _options) do
    Enum.map(keys, &Message.iolist(:delete, key: &1))
    |> socket_send(socket)

    errors = Enum.reduce(keys, %{}, fn key, acc ->
      with {:ok, message} <- recv_message(socket) do
        case message do
          %{status: 0} -> acc
          %{value: reason} -> Map.put(acc, key, Reason.tr(reason))
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

  # Single set
  def set(socket, {key, value}, options) do
    set(socket, [{key, value}], options)
    |> response_for(key)
  end

  # Multi set
  def set(socket, keys_and_values, options) do
    storage_commands(:set, keys_and_values, options)
    |> socket_send(socket)

    storage_reponses(keys_and_values, socket, not_stored: :exists)
  end

  # Single add
  def add(socket, {key, value}, options) do
    add(socket, [{key, value}], options)
    |> response_for(key)
  end

  # Multi add
  def add(socket, keys_and_values, options) do
    storage_commands(:add, keys_and_values, options)
    |> socket_send(socket)

    storage_reponses(keys_and_values, socket)
  end

  # Single replace
  def replace(socket, {key, value}, options) do
    replace(socket, [{key, value}], options)
    |> response_for(key)
  end

  # Multi replace
  def replace(socket, keys_and_values, options) do
    storage_commands(:replace, keys_and_values, options)
    |> socket_send(socket)

    storage_reponses(keys_and_values, socket, not_found: :not_stored)
  end

  def get(socket, key, options) when is_binary(key) do
    case get(socket, [key], options) do
      {status, values} -> {status, values[key]}
    end
  end

  def get(socket, keys, options) do
    Enum.map(keys, &Message.iolist(:getkq, key: &1))
    |> iolist_append(Message.iolist(:noop))
    |> socket_send(socket)

    with {:ok, messages} <- recv_messages(socket) do
      values = Map.new(messages, fn message ->
        value = Coder.decode(options[:coder], message.extras[:flags], message.value)
        value = if options[:cas] do
          {value, message.cas}
        else
          value
        end
        {message.key, value}
      end)
      {:ok, values}
    end
  end

  defp storage_commands(opcode, keys_and_values, options) do
    Enum.map(keys_and_values, fn {key, value} ->
      {flags, value} = Coder.encode(options[:coder], value)
      extras = [flags: flags, ttl: options[:ttl]]
      Message.iolist(opcode, key: key, value: value, extras: extras)
    end)
    |> iolist_append(Message.new(:noop))
  end

  defp storage_reponses(keys_and_values, socket, tr_reason \\ []) do
    with {:ok, messages} <- recv_messages(socket) do
      errors =
        keys_and_values
        |> Stream.zip(messages)
        |> Enum.reduce(%{}, fn {{key, _value}, message}, acc ->
          case message do
            %{status: 0} -> acc
            %{value: reason} ->
              reason = Reason.tr(reason)
              # Ugh, binary protocol responds with :not_found for :replace commands while
              # the ascii protocol responds with :not_stored. tr_reason argument is to override.
              reason = case tr_reason do
                [{^reason, reason}] -> reason
                _ -> reason
              end
              Map.put(acc, key, reason)
          end
        end)

      if errors == %{} do
        {:ok, :stored}
      else
        {:error, errors}
      end
    end
  end

  # Most non-multi commands just delegate to multi version of the command,
  # then extract a single value to return. This function does this.
  defp response_for(response, key) do
    with {status, %{^key => reason}} <- response do
      {status, reason}
    end
  end

  def recv_header(socket) do
    with {:ok, data} <- :gen_tcp.recv(socket, 24) do
      {:ok, Message.from_binary(data)}
    end
  end

  def recv_body(%{total_body: 0} = message, _socket), do: {:ok, message}
  def recv_body(%{total_body: total_body} = message, socket) do
    with {:ok, data} <- :gen_tcp.recv(socket, total_body) do
      {:ok, Message.from_binary(message, data)}
    end
  end

  defp recv_messages(socket, messages \\ []) do
    with {:ok, message} = recv_message(socket) do
      case message do
        %{opcode: :noop} -> {:ok, Enum.reverse(messages)}
        message -> recv_messages(socket, [message | messages])
      end
    end
  end

  defp recv_message(socket) do
    with {:ok, message} <- recv_header(socket) do
      recv_body(message, socket)
    end
  end

  defp socket_send(iolist, socket) do
    :ok = :gen_tcp.send(socket, iolist)
  end

end
