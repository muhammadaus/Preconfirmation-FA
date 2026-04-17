import { NextResponse } from "next/server";
import {
  encodeFunctionData,
  parseEther,
  createPublicClient,
  http,
  parseAbiItem,
  type Hex,
} from "viem";
import { base } from "viem/chains";
import { pendingTransfersAbi, PENDING_TRANSFERS_ADDRESS, DEPLOY_BLOCK, LOG_BLOCK_RANGE } from "../../lib/contract";
import { generateSecret, computeCommit, secretToShortCode } from "../../lib/secret";

const client = createPublicClient({ chain: base, transport: http() });

/**
 * POST /api/transfers — Build a createETH intent.
 *
 * Body: { sender, receiver, amountEth, expiryMinutes }
 * Returns: { id, to, data, value, secret, shortCode, commit }
 *
 * The caller signs and broadcasts the { to, data, value } triple.
 * `secret` and `shortCode` are returned ONLY in this response — the server
 * does not persist them. The caller must store/relay them out-of-band.
 */
export async function POST(request: Request) {
  try {
    const body = await request.json();
    const { sender, receiver, amountEth, expiryMinutes = 60 } = body;

    if (!sender || !receiver || !amountEth) {
      return NextResponse.json(
        { error: "Missing required fields: sender, receiver, amountEth" },
        { status: 400 }
      );
    }

    const value = parseEther(String(amountEth));
    const expirySeconds = BigInt(Math.floor(Date.now() / 1000) + Number(expiryMinutes) * 60);

    // Preview the transfer ID
    const id = await client.readContract({
      address: PENDING_TRANSFERS_ADDRESS,
      abi: pendingTransfersAbi,
      functionName: "previewId",
      args: [
        sender as Hex,
        receiver as Hex,
        "0x0000000000000000000000000000000000000000",
        value,
      ],
    });

    // Generate secret and commitment
    const secret = generateSecret();
    const commit = computeCommit(id as Hex, secret);
    const shortCode = secretToShortCode(secret);

    // Encode the createETH calldata
    const data = encodeFunctionData({
      abi: pendingTransfersAbi,
      functionName: "createETH",
      args: [receiver as Hex, commit, expirySeconds],
    });

    return NextResponse.json({
      id,
      to: PENDING_TRANSFERS_ADDRESS,
      data,
      value: value.toString(),
      secret,
      shortCode,
      commit,
    });
  } catch (e: unknown) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : "Unknown error" },
      { status: 500 }
    );
  }
}

/**
 * GET /api/transfers?user=0x... — List TransferCreated events for a user.
 *
 * Returns an array of transfer summaries (id, sender, receiver, amount, status).
 */
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const user = searchParams.get("user") as Hex | null;

  if (!user) {
    return NextResponse.json(
      { error: "Missing query param: user" },
      { status: 400 }
    );
  }

  try {
    const latestBlock = await client.getBlockNumber();
    const event = parseAbiItem(
      "event TransferCreated(bytes32 indexed id, address indexed sender, address indexed receiver, address token, uint256 amount, bytes32 commit, uint64 expiry)"
    );

    // Paginate getLogs in chunks to respect public RPC limits
    const fetchLogs = async (args: Record<string, Hex>) => {
      const allLogs = [];
      for (let from = DEPLOY_BLOCK; from <= latestBlock; from += LOG_BLOCK_RANGE + 1n) {
        const to = from + LOG_BLOCK_RANGE > latestBlock ? latestBlock : from + LOG_BLOCK_RANGE;
        const logs = await client.getLogs({
          address: PENDING_TRANSFERS_ADDRESS,
          event,
          args,
          fromBlock: from,
          toBlock: to,
        });
        allLogs.push(...logs);
      }
      return allLogs;
    };

    const [sentLogs, receivedLogs] = await Promise.all([
      fetchLogs({ sender: user }),
      fetchLogs({ receiver: user }),
    ]);

    const seen = new Set<string>();
    const unique = [...sentLogs, ...receivedLogs].filter((log) => {
      const id = log.args.id as string;
      if (seen.has(id)) return false;
      seen.add(id);
      return true;
    });

    // Fetch current status for each
    const transfers = await Promise.all(
      unique.map(async (log) => {
        const id = log.args.id as Hex;
        const t = (await client.readContract({
          address: PENDING_TRANSFERS_ADDRESS,
          abi: pendingTransfersAbi,
          functionName: "getTransfer",
          args: [id],
        })) as {
          sender: string;
          receiver: string;
          token: string;
          amount: bigint;
          expiry: bigint;
          status: number;
        };
        return {
          id,
          sender: t.sender,
          receiver: t.receiver,
          amount: t.amount.toString(),
          expiry: Number(t.expiry),
          status: Number(t.status),
        };
      })
    );

    return NextResponse.json({ transfers });
  } catch (e: unknown) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : "Unknown error" },
      { status: 500 }
    );
  }
}
