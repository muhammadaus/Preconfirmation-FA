import { NextResponse } from "next/server";
import { createPublicClient, http, type Hex } from "viem";
import { base } from "viem/chains";
import { pendingTransfersAbi, PENDING_TRANSFERS_ADDRESS } from "../../../lib/contract";

const client = createPublicClient({ chain: base, transport: http() });

/**
 * GET /api/transfers/:id — Read a single transfer's on-chain state.
 *
 * Returns the full Pending struct (minus the secret, which is never stored).
 */
export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;

  try {
    const t = (await client.readContract({
      address: PENDING_TRANSFERS_ADDRESS,
      abi: pendingTransfersAbi,
      functionName: "getTransfer",
      args: [id as Hex],
    })) as {
      sender: string;
      receiver: string;
      token: string;
      amount: bigint;
      commit: Hex;
      expiry: bigint;
      status: number;
    };

    return NextResponse.json({
      id,
      sender: t.sender,
      receiver: t.receiver,
      token: t.token,
      amount: t.amount.toString(),
      expiry: Number(t.expiry),
      status: Number(t.status),
    });
  } catch (e: unknown) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : "Unknown error" },
      { status: 500 }
    );
  }
}
