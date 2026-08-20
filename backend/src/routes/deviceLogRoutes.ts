import { Router } from "express";
import { z } from "zod";
import {
  completeDeviceLogUpload,
  initiateDeviceLogUpload,
  type DeviceLogMetadata
} from "../deviceLogs/deviceLogService.js";
import { requireFirebaseAuth, type AuthenticatedRequest } from "../firebase/auth.js";
import { asyncHandler } from "../http/asyncHandler.js";

const kindSchema = z.enum(["crash", "feedback"]);

const initiateSchema = z.object({
  kind: kindSchema,
  groupId: z.string().max(128).optional(),
  appVersion: z.string().max(128).optional(),
  deviceModel: z.string().max(128).optional(),
  androidVersion: z.string().max(128).optional(),
  description: z.string().max(2000).optional()
});

const metadataSchema = z.object({
  userId: z.string().min(1).max(128),
  groupId: z.string().max(256),
  appVersion: z.string().max(256),
  deviceModel: z.string().max(256),
  androidVersion: z.string().max(256),
  timestamp: z.string().min(1).max(64),
  kind: kindSchema,
  description: z.string().max(256)
});

const completeSchema = z.object({
  storagePath: z.string().min(1).max(512),
  metadata: metadataSchema
});

export function createDeviceLogRoutes() {
  const router = Router();

  router.post(
    "/v1/device-logs/upload",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const body = initiateSchema.parse(request.body);
      const result = await initiateDeviceLogUpload({
        userId: authRequest.auth.uid,
        kind: body.kind,
        groupId: body.groupId,
        appVersion: body.appVersion,
        deviceModel: body.deviceModel,
        androidVersion: body.androidVersion,
        description: body.description
      });
      response.status(200).json(result);
    })
  );

  router.post(
    "/v1/device-logs/complete",
    requireFirebaseAuth,
    asyncHandler(async (request, response) => {
      const authRequest = request as AuthenticatedRequest;
      const body = completeSchema.parse(request.body);
      const result = await completeDeviceLogUpload({
        userId: authRequest.auth.uid,
        storagePath: body.storagePath,
        metadata: body.metadata as DeviceLogMetadata
      });
      response.status(200).json(result);
    })
  );

  return router;
}
