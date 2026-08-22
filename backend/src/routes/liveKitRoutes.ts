import { Router } from "express";
import { z } from "zod";
import { requireFirebaseAuth, type AuthenticatedRequest } from "../firebase/auth.js";
import { asyncHandler } from "../http/asyncHandler.js";
import {
  issueGroupLiveKitToken,
  listLiveGroupParticipantUserIds
} from "../livekit/liveKitTokenService.js";

const liveKitTokenSchema = z.object({
  groupId: z.string().min(1),
  deviceId: z.string().min(1),
  serviceSessionId: z.string().min(1),
  livekitSessionId: z.string().min(1)
});

const groupIdSchema = z
  .string()
  .min(1)
  .max(128)
  .regex(/^[^.#$\[\]\/]+$/);

export function createLiveKitRoutes() {
  const router = Router();

  router.get(
    "/v1/livekit/groups/:groupId/participants",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const groupId = groupIdSchema.parse(request.params.groupId);
      const participantUserIds = await listLiveGroupParticipantUserIds(
        authRequest.auth.uid,
        groupId
      );
      response.status(200).json({ participantUserIds });
    })
  );

  router.post(
    "/v1/livekit/token",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const body = liveKitTokenSchema.parse(request.body);
      const result = await issueGroupLiveKitToken({
        userId: authRequest.auth.uid,
        groupId: body.groupId,
        deviceId: body.deviceId,
        serviceSessionId: body.serviceSessionId,
        livekitSessionId: body.livekitSessionId
      });

      response.status(200).json(result);
    })
  );

  return router;
}
