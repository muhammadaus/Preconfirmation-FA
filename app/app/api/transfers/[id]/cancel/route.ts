import { NextResponse } from "next/server";
import { encodeFunctionData, type Hex } from "viem";
import { pendingTransfersAbi, PENDING_TRANSFERS_ADDRESS } from "../../../../lib/contract";

/**
 * POST /api/transfers/:id/cancel — Build a cancel intent.
 *
 * Body: {} (no fields required — sender identity is verified on-chain)
 * Returns: { to, data } — the caller signs and broadcasts.
 */
export async function POST(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;

  try {
    const data = encodeFunctionData({
      abi: pendingTransfersAbi,
      functionName: "cancel",
      args: [id as Hex],
    });

    return NextResponse.json({
      to: PENDING_TRANSFERS_ADDRESS,
      data,
    });
  } catch (e: unknown) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : "Unknown error" },
      { status: 500 }
    );
  }
}
