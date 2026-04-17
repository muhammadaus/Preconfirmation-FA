import { NextResponse } from "next/server";

export async function POST(request: Request) {
  const body = await request.json();
  console.log("Farcaster webhook:", body);
  return NextResponse.json({ success: true });
}

export async function GET() {
  return NextResponse.json({ success: true });
}
