import { NextResponse } from "next/server";
import { encodeFunctionData, type Hex } from "viem";
import { pendingTransfersAbi, PENDING_TRANSFERS_ADDRESS } from "../../../../lib/contract";

/**
 * POST /api/transfers/:id/claim — Build a claim intent.
 *
 * Body: { secret }
 * Returns: { to, data } — the caller signs and broadcasts.
 *
 * The secret is used only to encode calldata; it is NOT persisted.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;

  try {
    const body = await request.json();
    const { secret } = body;

    if (!secret) {
      return NextResponse.json(
        { error: "Missing required field: secret" },
        { status: 400 }
      );
    }

    const data = encodeFunctionData({
      abi: pendingTransfersAbi,
      functionName: "claim",
      args: [id as Hex, secret as Hex],
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
